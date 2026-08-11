import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/toolchain/archive_extractor.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/compose/toolchain/host_manager_patcher.dart';
import 'package:xcross/src/errors.dart';

typedef DownloadToFile = Future<void> Function(String url, File file);
typedef ExtractArchive =
    Future<void> Function(File archive, Directory destination);
typedef PatchCompilerJar = Future<void> Function(File jar);
typedef RunChecked =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });
typedef InstallRoot =
    Future<String> Function(ComposeSetupOptions options, {required bool force});

final class ComposeToolchainInstaller {
  const ComposeToolchainInstaller()
    : _downloadToFile = null,
      _extractArchive = null,
      _patchCompilerJar = null,
      _runChecked = null,
      _installRoot = null;

  const ComposeToolchainInstaller.withSeams({
    DownloadToFile? downloadToFile,
    ExtractArchive? extractArchive,
    PatchCompilerJar? patchCompilerJar,
    RunChecked? runChecked,
    InstallRoot? installRoot,
  }) : _downloadToFile = downloadToFile,
       _extractArchive = extractArchive,
       _patchCompilerJar = patchCompilerJar,
       _runChecked = runChecked,
       _installRoot = installRoot;

  final DownloadToFile? _downloadToFile;
  final ExtractArchive? _extractArchive;
  final PatchCompilerJar? _patchCompilerJar;
  final RunChecked? _runChecked;
  final InstallRoot? _installRoot;

  Future<String> install({
    required ComposeSetupOptions options,
    bool force = false,
  }) async {
    _rejectUnsupported(options.host);
    if (!force && _isComplete(options)) return options.kotlinHome;
    final installRoot = _installRoot;
    if (installRoot != null) return installRoot(options, force: force);

    final cache = Directory(options.cacheRoot);
    await cache.create(recursive: true);
    final downloads = await cache.createTemp('compose-downloads-');
    final hostExtract = Directory('${options.kotlinHome}.host');
    final staging = Directory('${options.kotlinHome}.staging');
    final overlayExtract = Directory('${options.kotlinHome}.overlay');
    try {
      if (hostExtract.existsSync()) await hostExtract.delete(recursive: true);
      if (staging.existsSync()) await staging.delete(recursive: true);
      if (overlayExtract.existsSync()) {
        await overlayExtract.delete(recursive: true);
      }
      await hostExtract.create(recursive: true);
      await overlayExtract.create(recursive: true);

      final hostArchive = File(
        p.join(downloads.path, options.host.hostArtifact(options.version)),
      );
      final overlayArchive = File(
        p.join(
          downloads.path,
          ComposeHost.macosX64OverlayArtifact(options.version),
        ),
      );
      await _download(options.hostArchiveUrl, hostArchive);
      await _download(options.overlayArchiveUrl, overlayArchive);
      await _extract(hostArchive, hostExtract);
      await _extract(overlayArchive, overlayExtract);
      await _moveRoot(_archiveRoot(hostExtract), staging);
      await _copyOverlay(_archiveRoot(overlayExtract), staging);
      _restoreExecutables(options.host, staging.path);
      await _patchJars(staging);
      await _warmDependencies(options, staging.path);
      await _atomicInstall(
        staging,
        Directory(options.kotlinHome),
        force: force,
      );
      return options.kotlinHome;
    } finally {
      if (downloads.existsSync()) await downloads.delete(recursive: true);
      if (hostExtract.existsSync()) await hostExtract.delete(recursive: true);
      if (overlayExtract.existsSync()) {
        await overlayExtract.delete(recursive: true);
      }
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  bool _isComplete(ComposeSetupOptions options) =>
      File(options.host.konancExecutable(options.kotlinHome)).existsSync();

  void _rejectUnsupported(ComposeHost host) {
    if (host != ComposeHost.linuxX64 && host != ComposeHost.windowsX64) {
      throw XcrossError(
        'Compose Kotlin/Native toolchain supports Linux x64 and Windows x64 only; '
        '${host.classifier} is not supported.',
      );
    }
  }

  Future<void> _download(String url, File file) =>
      (_downloadToFile ?? _defaultDownload)(url, file);

  Future<void> _extract(File archive, Directory destination) =>
      (_extractArchive ?? ArchiveExtractor.extractArchive)(
        archive,
        destination,
      );

  Future<void> _patch(File jar) =>
      (_patchCompilerJar ?? _defaultPatchCompilerJar)(jar);

  Future<void> _run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) => (_runChecked ?? _defaultRunChecked)(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  static Future<void> _defaultDownload(String url, File file) =>
      Downloader.downloadToFile(url, file);

  static Future<void> _defaultPatchCompilerJar(File jar) async {
    patchKotlinNativeJar(jar.path);
  }

  static Future<void> _defaultRunChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) => ProcessRunner.runChecked(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  Future<void> _copyOverlay(Directory overlay, Directory staging) async {
    await _copyDirectory(
      Directory(p.join(overlay.path, 'konan', 'targets', 'ios_arm64')),
      Directory(p.join(staging.path, 'konan', 'targets', 'ios_arm64')),
    );
    await _copyDirectory(
      Directory(p.join(overlay.path, 'klib', 'platform', 'ios_arm64')),
      Directory(p.join(staging.path, 'klib', 'platform', 'ios_arm64')),
    );
  }

  Directory _archiveRoot(Directory extracted) {
    final entries = extracted.listSync(followLinks: false);
    if (entries.length == 1 && entries.single is Directory) {
      return entries.single as Directory;
    }
    return extracted;
  }

  Future<void> _moveRoot(Directory source, Directory destination) async {
    if (destination.existsSync()) await destination.delete(recursive: true);
    await destination.parent.create(recursive: true);
    try {
      await source.rename(destination.path);
    } on FileSystemException {
      await _copyDirectory(source, destination);
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    if (!source.existsSync()) {
      throw XcrossError('Kotlin/Native macOS overlay missing ${source.path}.');
    }
    await destination.create(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: source.path);
      final target = p.join(destination.path, relative);
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        await entity.copy(target);
      } else {
        throw XcrossError(
          'refusing to copy link from Kotlin/Native overlay: ${entity.path}',
        );
      }
    }
  }

  void _restoreExecutables(ComposeHost host, String kotlinHome) {
    final konanc = File(host.konancExecutable(kotlinHome));
    if (konanc.existsSync()) ProcessRunner.makeExecutable(konanc.path);
    final bin = Directory(p.join(kotlinHome, 'bin'));
    if (!bin.existsSync()) return;
    for (final entity in bin.listSync()) {
      if (entity is File) ProcessRunner.makeExecutable(entity.path);
    }
  }

  Future<void> _patchJars(Directory root) async {
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          p.basename(entity.path) == 'kotlin-native-compiler-embeddable.jar') {
        await _patch(entity);
      }
    }
  }

  Future<void> _warmDependencies(
    ComposeSetupOptions options,
    String stagingHome,
  ) async {
    final executable = options.host.konancExecutable(stagingHome);
    final scratch = await Directory(
      options.cacheRoot,
    ).createTemp('compose-konanc-warmup-');
    try {
      final source = File(p.join(scratch.path, 'hello.kt'));
      await source.writeAsString('fun main() { println("hello") }\n');
      final invocation = options.host.invokeExecutable(executable, [
        source.path,
        '-o',
        p.join(scratch.path, 'hello'),
      ]);
      await _run(invocation.first, invocation.skip(1).toList());
    } finally {
      if (scratch.existsSync()) await scratch.delete(recursive: true);
    }
  }

  Future<void> _atomicInstall(
    Directory staging,
    Directory destination, {
    required bool force,
  }) async {
    if (destination.existsSync()) {
      if (!force) {
        throw XcrossError(
          '${destination.path} already exists. Use force to reinstall.',
        );
      }
      await destination.delete(recursive: true);
    }
    await destination.parent.create(recursive: true);
    try {
      await staging.rename(destination.path);
    } on FileSystemException {
      await _copyDirectory(staging, destination);
      await staging.delete(recursive: true);
    }
  }
}
