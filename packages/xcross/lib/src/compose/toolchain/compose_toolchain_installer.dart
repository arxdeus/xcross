import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/toolchain/archive_extractor.dart';
import 'package:xcross/src/compose/toolchain/host_manager_patcher.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/compose/compose_directory_publisher.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/compose/compose_install_effects.dart';
import 'package:xcross/src/shared/compose/compose_setup_options.dart';
import 'package:xcross/src/shared/compose/verified_compose_artifact_acquirer.dart';

export 'package:xcross/src/shared/compose/compose_install_effects.dart';

final class ComposeToolchainInstaller<T extends PlatformHostInterface> {
  const ComposeToolchainInstaller(this.runner, this.downloader)
    : _downloadToFile = null,
      _digestFile = null,
      _extractArchive = null,
      _patchCompilerJar = null,
      _runChecked = null,
      _installRoot = null,
      _renameDirectory = null;

  const ComposeToolchainInstaller.withSeams(
    this.runner, {
    required this.downloader,
    DownloadToFile? downloadToFile,
    DigestFile? digestFile,
    ExtractArchive? extractArchive,
    PatchCompilerJar? patchCompilerJar,
    RunChecked? runChecked,
    InstallRoot? installRoot,
    RenameDirectory? renameDirectory,
  }) : _downloadToFile = downloadToFile,
       _digestFile = digestFile,
       _extractArchive = extractArchive,
       _patchCompilerJar = patchCompilerJar,
       _runChecked = runChecked,
       _installRoot = installRoot,
       _renameDirectory = renameDirectory;

  final ProcessRunner<T> runner;
  final Downloader downloader;
  final DownloadToFile? _downloadToFile;
  final DigestFile? _digestFile;
  final ExtractArchive? _extractArchive;
  final PatchCompilerJar? _patchCompilerJar;
  final RunChecked? _runChecked;
  final InstallRoot? _installRoot;
  final RenameDirectory? _renameDirectory;

  Future<String> install({
    required ComposeSetupOptions<T> options,
    bool force = false,
  }) async {
    if (!force && _isComplete(options)) return options.kotlinHome;
    final artifacts = VerifiedComposeArtifactAcquirer(
      downloadToFile: _downloadToFile ?? downloader.downloadToFile,
      digestFile: _digestFile ?? digestComposeArtifact,
      extractArchive:
          _extractArchive ?? ArchiveExtractor(runner.host).extractArchive,
    );
    final installRoot = _installRoot;
    if (installRoot != null) return installRoot(options, force: force);

    final cache = runner.host.fileSystem.directory(options.cacheRoot);
    await cache.create(recursive: true);
    final downloads = await cache.createTemp('compose-downloads-');
    final hostExtract = await cache.createTemp('compose-host-');
    final staging = await runner.host.fileSystem
        .directory(p.dirname(options.kotlinHome))
        .createTemp('.compose-staging-');
    final overlayExtract = options.overlayArchiveUrl == null
        ? null
        : await cache.createTemp('compose-overlay-');
    try {
      final hostArchive = runner.host.fileSystem.file(
        p.join(downloads.path, options.host.hostArtifact(options.version)),
      );
      final overlayArchive = options.overlayArchiveUrl == null
          ? null
          : runner.host.fileSystem.file(
              p.join(
                downloads.path,
                options.host
                    .installationArtifacts(options.version)
                    .skip(1)
                    .first,
              ),
            );
      final hostSha256 = artifacts.requireDigest(
        p.basename(hostArchive.path),
        options.hostArchiveSha256,
      );
      final overlaySha256 = overlayArchive == null
          ? null
          : artifacts.requireDigest(
              p.basename(overlayArchive.path),
              options.overlayArchiveSha256,
            );
      await artifacts.downloadToFile(options.hostArchiveUrl, hostArchive);
      await artifacts.verifyDigest(hostArchive, hostSha256);
      if (overlayArchive != null) {
        await artifacts.downloadToFile(
          options.overlayArchiveUrl!,
          overlayArchive,
        );
        await artifacts.verifyDigest(overlayArchive, overlaySha256!);
      }
      await artifacts.extract(hostArchive, hostExtract);
      if (overlayArchive != null && overlayExtract != null) {
        await artifacts.extract(overlayArchive, overlayExtract);
      }
      await _moveRoot(_archiveRoot(hostExtract), staging);
      _restoreExecutables(options.host, staging.path);
      await _warmDependencies(options, staging.path);
      if (overlayExtract != null) {
        await _copyOverlay(_archiveRoot(overlayExtract), staging);
      }
      await _patchJars(staging);
      await _writeCompletionMarker(options, staging);
      await ComposeDirectoryPublisher(
        files: runner.host.fileSystem,
        renameDirectory: _rename,
      ).publish(
        staging,
        runner.host.fileSystem.directory(options.kotlinHome),
        force: force,
      );
      return options.kotlinHome;
    } finally {
      if (downloads.existsSync()) await downloads.delete(recursive: true);
      if (hostExtract.existsSync()) await hostExtract.delete(recursive: true);
      if (overlayExtract != null && overlayExtract.existsSync()) {
        await overlayExtract.delete(recursive: true);
      }
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  static bool isComplete(ComposeSetupOptions options) {
    if (!options.host.host.fileSystem
        .file(options.host.konancExecutable(options.kotlinHome))
        .existsSync()) {
      return false;
    }
    final marker = options.host.host.fileSystem.file(
      completionMarkerPath(options.kotlinHome),
    );
    if (!marker.existsSync()) return false;
    return marker.readAsStringSync() == completionMarkerContent(options);
  }

  bool _isComplete(ComposeSetupOptions options) => isComplete(options);

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

  Future<Directory> _rename(Directory source, String newPath) =>
      (_renameDirectory ?? ((source, newPath) => source.rename(newPath)))(
        source,
        newPath,
      );

  Future<void> _defaultPatchCompilerJar(File jar) async {
    KotlinNativeJarPatcher(runner.host.fileSystem).patch(jar.path);
  }

  Future<void> _defaultRunChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) => runner.runTool(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  Future<void> _copyOverlay(Directory overlay, Directory staging) async {
    await _copyDirectory(
      runner.host.fileSystem.directory(
        p.join(overlay.path, 'konan', 'targets', 'ios_arm64'),
      ),
      runner.host.fileSystem.directory(
        p.join(staging.path, 'konan', 'targets', 'ios_arm64'),
      ),
    );
    await _copyDirectory(
      runner.host.fileSystem.directory(
        p.join(overlay.path, 'klib', 'platform', 'ios_arm64'),
      ),
      runner.host.fileSystem.directory(
        p.join(staging.path, 'klib', 'platform', 'ios_arm64'),
      ),
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
      await _rename(source, destination.path);
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
        await runner.host.fileSystem.directory(target).create(recursive: true);
      } else if (entity is File) {
        await runner.host.fileSystem
            .directory(p.dirname(target))
            .create(recursive: true);
        await entity.copy(target);
      } else {
        throw XcrossError(
          'refusing to copy link from Kotlin/Native overlay: ${entity.path}',
        );
      }
    }
  }

  void _restoreExecutables(ComposeHost<T> host, String kotlinHome) {
    final konanc = runner.host.fileSystem.file(
      host.konancExecutable(kotlinHome),
    );
    if (konanc.existsSync()) runner.makeExecutable(konanc.path);
    final bin = runner.host.fileSystem.directory(p.join(kotlinHome, 'bin'));
    if (!bin.existsSync()) return;
    for (final entity in bin.listSync()) {
      if (entity is File) runner.makeExecutable(entity.path);
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
    ComposeSetupOptions<T> options,
    String stagingHome,
  ) async {
    final executable = options.host.konancExecutable(stagingHome);
    final scratch = await runner.host.fileSystem
        .directory(options.cacheRoot)
        .createTemp('compose-konanc-warmup-');
    try {
      final source = runner.host.fileSystem.file(
        p.join(scratch.path, 'hello.kt'),
      );
      await source.writeAsString('fun main() { println("hello") }\n');
      final invocation = options.host.invocation(executable, [
        source.path,
        '-target',
        options.host.konanTarget,
        '-o',
        p.join(scratch.path, 'hello'),
      ]);
      await _run(
        invocation.executable,
        invocation.arguments,
        environment: {
          ...options.environment,
          'KONAN_DATA_DIR': options.konanCache,
        },
      );
    } finally {
      if (scratch.existsSync()) await scratch.delete(recursive: true);
    }
  }

  Future<void> _writeCompletionMarker(
    ComposeSetupOptions options,
    Directory root,
  ) async {
    final marker = runner.host.fileSystem.file(completionMarkerPath(root.path));
    await marker.parent.create(recursive: true);
    await marker.writeAsString(completionMarkerContent(options));
  }

  static String completionMarkerContent(ComposeSetupOptions options) =>
      'version=${options.version}\n'
      'host=${options.host.classifier}\n'
      'hostArchive=${options.host.hostArtifact(options.version)}\n'
      'hostSha256=${options.hostArchiveSha256}\n'
      'overlayArchive=${options.host.installationArtifacts(options.version).skip(1).firstOrNull ?? 'none'}\n'
      'overlaySha256=${options.overlayArchiveSha256}\n';

  static String completionMarkerPath(String kotlinHome) =>
      p.join(kotlinHome, '.xcross-compose-toolchain-complete');
}
