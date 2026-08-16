import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/toolchain/archive_extractor.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/compose/toolchain/host_manager_patcher.dart';
import 'package:xcross/src/errors.dart';

typedef DownloadToFile = Future<void> Function(String url, File file);
typedef DigestFile = Future<String> Function(File file);
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
typedef RenameDirectory =
    Future<Directory> Function(Directory source, String newPath);

final class ComposeToolchainInstaller {
  const ComposeToolchainInstaller()
    : _downloadToFile = null,
      _digestFile = null,
      _extractArchive = null,
      _patchCompilerJar = null,
      _runChecked = null,
      _installRoot = null,
      _renameDirectory = null;

  const ComposeToolchainInstaller.withSeams({
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

  final DownloadToFile? _downloadToFile;
  final DigestFile? _digestFile;
  final ExtractArchive? _extractArchive;
  final PatchCompilerJar? _patchCompilerJar;
  final RunChecked? _runChecked;
  final InstallRoot? _installRoot;
  final RenameDirectory? _renameDirectory;

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
    final hostExtract = await cache.createTemp('compose-host-');
    final staging = await Directory(
      p.dirname(options.kotlinHome),
    ).createTemp('.compose-staging-');
    final overlayExtract = await cache.createTemp('compose-overlay-');
    try {
      final hostArchive = File(
        p.join(downloads.path, options.host.hostArtifact(options.version)),
      );
      final overlayArchive = File(
        p.join(
          downloads.path,
          ComposeHost.macosX64OverlayArtifact(options.version),
        ),
      );
      final hostSha256 = _requireDigest(
        p.basename(hostArchive.path),
        options.hostArchiveSha256,
      );
      final overlaySha256 = _requireDigest(
        p.basename(overlayArchive.path),
        options.overlayArchiveSha256,
      );
      await _download(options.hostArchiveUrl, hostArchive);
      await _verifyDigest(hostArchive, hostSha256);
      await _download(options.overlayArchiveUrl, overlayArchive);
      await _verifyDigest(overlayArchive, overlaySha256);
      await _extract(hostArchive, hostExtract);
      await _extract(overlayArchive, overlayExtract);
      await _moveRoot(_archiveRoot(hostExtract), staging);
      _restoreExecutables(options.host, staging.path);
      await _warmDependencies(options, staging.path);
      await _copyOverlay(_archiveRoot(overlayExtract), staging);
      await _patchJars(staging);
      await _writeCompletionMarker(options, staging);
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

  static bool isComplete(ComposeSetupOptions options) {
    if (!File(options.host.konancExecutable(options.kotlinHome)).existsSync()) {
      return false;
    }
    final marker = File(completionMarkerPath(options.kotlinHome));
    if (!marker.existsSync()) return false;
    return marker.readAsStringSync() == completionMarkerContent(options);
  }

  bool _isComplete(ComposeSetupOptions options) => isComplete(options);

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

  String _requireDigest(String artifact, String? expectedSha256) {
    if (expectedSha256 == null) {
      throw XcrossError(
        'No pinned SHA-256 digest for Kotlin/Native $artifact.',
      );
    }
    return expectedSha256;
  }

  Future<void> _verifyDigest(File file, String expectedSha256) async {
    final artifact = p.basename(file.path);
    final actualSha256 = await (_digestFile ?? _defaultDigestFile)(file);
    if (actualSha256.toLowerCase() != expectedSha256.toLowerCase()) {
      throw XcrossError(
        'Kotlin/Native archive SHA-256 mismatch for $artifact: expected $expectedSha256, got $actualSha256.',
      );
    }
  }

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

  Future<Directory> _rename(Directory source, String newPath) =>
      (_renameDirectory ?? ((source, newPath) => source.rename(newPath)))(
        source,
        newPath,
      );

  static Future<void> _defaultDownload(String url, File file) =>
      Downloader.downloadToFile(url, file);

  static Future<String> _defaultDigestFile(File file) =>
      sha256.bind(file.openRead()).first.then((digest) => digest.toString());

  static Future<void> _defaultPatchCompilerJar(File jar) async {
    patchKotlinNativeJar(jar.path);
  }

  static Future<void> _defaultRunChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) => ProcessRunner.runTool(
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
        '-target',
        options.host.konanTarget,
        '-o',
        p.join(scratch.path, 'hello'),
      ]);
      await _run(invocation.first, invocation.skip(1).toList());
    } finally {
      if (scratch.existsSync()) await scratch.delete(recursive: true);
    }
  }

  Future<void> _writeCompletionMarker(
    ComposeSetupOptions options,
    Directory root,
  ) async {
    final marker = File(completionMarkerPath(root.path));
    await marker.parent.create(recursive: true);
    await marker.writeAsString(completionMarkerContent(options));
  }

  static String completionMarkerContent(ComposeSetupOptions options) =>
      'version=${options.version}\n'
      'host=${options.host.classifier}\n'
      'hostArchive=${options.host.hostArtifact(options.version)}\n'
      'hostSha256=${options.hostArchiveSha256}\n'
      'overlayArchive=${ComposeHost.macosX64OverlayArtifact(options.version)}\n'
      'overlaySha256=${options.overlayArchiveSha256}\n';

  static String completionMarkerPath(String kotlinHome) =>
      p.join(kotlinHome, '.xcross-compose-toolchain-complete');

  Future<void> _atomicInstall(
    Directory staging,
    Directory destination, {
    required bool force,
  }) async {
    await destination.parent.create(recursive: true);
    Directory? backupContainer;
    String? backupPath;
    if (destination.existsSync()) {
      if (!force) {
        throw XcrossError(
          '${destination.path} already exists. Use force to reinstall.',
        );
      }
      backupContainer = await destination.parent.createTemp('.compose-backup-');
      backupPath = p.join(backupContainer.path, 'toolchain');
      await _rename(destination, backupPath);
    }
    try {
      await _rename(staging, destination.path);
    } on FileSystemException catch (error) {
      await _restoreBackupOrThrow(destination, backupPath, error);
      await _deleteBackupContainer(backupContainer);
      throw XcrossError(
        'Failed to replace Compose Kotlin/Native cache at ${destination.path}: $error',
      );
    } catch (error) {
      await _restoreBackupOrThrow(destination, backupPath, error);
      await _deleteBackupContainer(backupContainer);
      rethrow;
    }
    await _deleteBackupContainer(backupContainer);
  }

  Future<void> _restoreBackupOrThrow(
    Directory destination,
    String? backupPath,
    Object installError,
  ) async {
    if (backupPath == null) return;
    try {
      if (destination.existsSync()) await destination.delete(recursive: true);
      if (Directory(backupPath).existsSync()) {
        await _rename(Directory(backupPath), destination.path);
      }
    } catch (restoreError) {
      throw XcrossError(
        'Failed to replace Compose Kotlin/Native cache at ${destination.path} and failed to restore the previous cache. '
        'Previous cache backup preserved at $backupPath. '
        'Install error: $installError. Restore error: $restoreError',
      );
    }
  }

  Future<void> _deleteBackupContainer(Directory? backupContainer) async {
    if (backupContainer != null && backupContainer.existsSync()) {
      await backupContainer.delete(recursive: true);
    }
  }
}
