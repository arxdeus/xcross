import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Resolves Flutter iOS engine artifacts needed for a debug iOS bundle.
///
/// On macOS, `flutter precache --ios` downloads these into
/// `bin/cache/artifacts/engine/ios/`. On Linux, Flutter skips iOS artifacts,
/// so we fetch them ourselves from `storage.googleapis.com`.
final class IosEngineCache {
  final String flutterRoot;

  IosEngineCache({required this.flutterRoot});

  /// `bin/cache/artifacts/engine/ios/` — debug/JIT artifacts only.
  String get _engineDir =>
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine', 'ios');

  /// Flutter.xcframework inside [_engineDir].
  String get flutterXcframework => p.join(_engineDir, 'Flutter.xcframework');

  /// `vm_isolate_snapshot.bin` from the host engine cache.
  String get vmSnapshotData =>
      p.join(_hostEngineDir, 'vm_isolate_snapshot.bin');

  /// `isolate_snapshot.bin` from the host engine cache.
  String get isolateSnapshotData =>
      p.join(_hostEngineDir, 'isolate_snapshot.bin');

  /// Host engine cache dir — where Flutter caches the host Dart engine.
  String get _hostEngineDir => p.join(
    flutterRoot,
    'bin',
    'cache',
    'artifacts',
    'engine',
    _hostEngineCacheDir,
  );

  /// Path to the Dart frontend_server snapshot. Prefers the AOT variant
  /// (`frontend_server_aot.dart.snapshot`) for speed; falls back to the JIT
  /// variant.
  String get frontendServer {
    final snapshotsDir = p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      'snapshots',
    );
    const jitSnapshot = 'frontend_server.dart.snapshot';
    for (final name in ['frontend_server_aot.dart.snapshot', jitSnapshot]) {
      final candidate = p.join(snapshotsDir, name);
      if (File(candidate).existsSync()) return candidate;
    }
    // Canonical fallback — used in error messages even if the file is missing.
    return p.join(snapshotsDir, jitSnapshot);
  }

  /// Patched SDK platform .dill — debug uses `flutter_patched_sdk/`.
  String get patchedSdkRoot => p.join(
    flutterRoot,
    'bin',
    'cache',
    'artifacts',
    'engine',
    'common',
    'flutter_patched_sdk',
  );

  static const _revisionStampName = '.xcross-engine-revision';

  /// Engine hash that pins the artifact set. Prefer the materialized cache
  /// stamp used by flutter_tools, falling back to the SDK's tracked revision.
  Future<String> _engineHash() async {
    for (final rel in [
      p.join('bin', 'cache', 'engine.stamp'),
      p.join('bin', 'internal', 'engine.version'),
    ]) {
      final file = File(p.join(flutterRoot, rel));
      if (file.existsSync()) {
        final text = (await file.readAsString()).trim();
        if (text.isNotEmpty) return text;
      }
    }
    throw FlutterBuildError(
      'IosEngineCache: Could not determine engine hash. Neither\n'
      'bin/internal/engine.version nor bin/cache/engine.stamp present under\n'
      '$flutterRoot. Run `<FLUTTER_ROOT>/bin/flutter --version` once to '
      'materialize the stamp.',
    );
  }

  /// Verify required iOS engine artifacts are present and belong to the
  /// selected engine revision. Safe to call repeatedly.
  Future<void> ensureArtifactsAvailable() async {
    final lock = await File(
      p.join(flutterRoot, 'bin', 'cache', 'lockfile'),
    ).open(mode: FileMode.append);
    try {
      await lock.lock();
      final hash = await _engineHash();
      if (!artifactIsCurrent(
        directory: _engineDir,
        revision: hash,
        officialStamp: Platform.isMacOS
            ? p.join(flutterRoot, 'bin', 'cache', 'ios-sdk.stamp')
            : null,
        requiredFiles: const [
          'Flutter.xcframework/ios-arm64/Flutter.framework/Flutter',
          'Flutter.xcframework/ios-arm64/Flutter.framework/Info.plist',
        ],
      )) {
        await _downloadIosArtifacts(hash);
      }
      final flutterSdkStamp = p.join(
        flutterRoot,
        'bin',
        'cache',
        'flutter_sdk.stamp',
      );
      if (!artifactIsCurrent(
        directory: _hostEngineDir,
        revision: hash,
        officialStamp: flutterSdkStamp,
        requiredFiles: const [
          'vm_isolate_snapshot.bin',
          'isolate_snapshot.bin',
        ],
      )) {
        await _downloadHostArtifacts(hash);
      }
      if (!artifactIsCurrent(
        directory: patchedSdkRoot,
        revision: hash,
        officialStamp: flutterSdkStamp,
        requiredFiles: const ['platform_strong.dill', 'vm_outline_strong.dill'],
      )) {
        await _downloadPatchedSdk(hash);
      }
      _validateDartSdk(hash);
    } finally {
      try {
        await lock.unlock();
      } on FileSystemException {
        // Lock acquisition failed, so there is nothing to release.
      }
      await lock.close();
    }
  }

  @visibleForTesting
  static bool artifactIsCurrent({
    required String directory,
    required String revision,
    String? officialStamp,
    List<String> requiredFiles = const [],
    List<String> requiredDirectories = const [],
  }) {
    final privateStamp = File(p.join(directory, _revisionStampName));
    final stamp = privateStamp.existsSync()
        ? privateStamp
        : officialStamp == null
        ? null
        : File(officialStamp);
    if (stamp == null || !stamp.existsSync()) return false;
    final revisionMatches = () {
      try {
        return stamp.readAsStringSync().trim() == revision;
      } on FileSystemException {
        return false;
      }
    }();
    if (!revisionMatches) return false;
    return requiredFiles.every((relative) {
          final file = File(p.join(directory, relative));
          try {
            return file.existsSync() && file.lengthSync() > 0;
          } on FileSystemException {
            return false;
          }
        }) &&
        requiredDirectories.every(
          (relative) => Directory(p.join(directory, relative)).existsSync(),
        );
  }

  void _validateDartSdk(String revision) {
    final stamp = File(
      p.join(flutterRoot, 'bin', 'cache', 'engine-dart-sdk.stamp'),
    );
    final runtime = File(
      p.join(
        flutterRoot,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        ProcessRunner.hostExecutableName('dart'),
      ),
    );
    final server = File(frontendServer);
    final current =
        stamp.existsSync() &&
        stamp.readAsStringSync().trim() == revision &&
        runtime.existsSync() &&
        runtime.lengthSync() > 0 &&
        server.existsSync() &&
        server.lengthSync() > 0;
    if (!current) {
      throw FlutterBuildError(
        'Flutter Dart SDK artifacts do not match engine $revision.\n'
        'Run `<FLUTTER_ROOT>/bin/flutter precache --force` and retry.',
      );
    }
  }

  Future<void> _downloadHostArtifacts(String hash) async {
    final url =
        '$flutterArtifactBaseUrl/$hash/$_hostEngineCacheDir/artifacts.zip';
    Log.logTrace('downloading Flutter host engine artifacts from $url');
    await _fetchAndInstall(
      url,
      _hostEngineDir,
      'host-artifacts-',
      revision: hash,
      requiredFiles: const ['vm_isolate_snapshot.bin', 'isolate_snapshot.bin'],
      label: 'Flutter host engine',
    );
  }

  Future<void> _downloadIosArtifacts(String hash) async {
    final url = '$flutterArtifactBaseUrl/$hash/ios/artifacts.zip';
    Log.logTrace('downloading Flutter iOS engine artifacts from $url');
    await _fetchAndInstall(
      url,
      _engineDir,
      'ios-artifacts-',
      revision: hash,
      requiredFiles: const [
        'Flutter.xcframework/ios-arm64/Flutter.framework/Flutter',
        'Flutter.xcframework/ios-arm64/Flutter.framework/Info.plist',
      ],
      label: 'Flutter iOS engine',
    );
  }

  Future<void> _downloadPatchedSdk(String hash) async {
    final leaf = p.basename(patchedSdkRoot);
    final url = '$flutterArtifactBaseUrl/$hash/$leaf.zip';
    Log.logTrace('downloading Flutter patched SDK from $url');
    await _fetchAndInstall(
      url,
      patchedSdkRoot,
      'patched-sdk-',
      revision: hash,
      extractedSubdirectory: leaf,
      requiredFiles: const ['platform_strong.dill', 'vm_outline_strong.dill'],
      label: 'Flutter patched SDK',
    );
  }

  /// Download [url] into a staging directory, validate it, then atomically
  /// replace [destDir].
  ///
  /// Pure Dart — no `curl`/`unzip` subprocess. The download follows redirects
  /// and retries transient failures; the archive package's posix-aware
  /// extractor restores unix permissions (exec bits) and symlinks.
  static Future<void> _fetchAndInstall(
    String url,
    String destDir,
    String tmpPrefix, {
    required String revision,
    required String label,
    String? extractedSubdirectory,
    List<String> requiredFiles = const [],
    List<String> requiredDirectories = const [],
  }) async {
    final parent = Directory(p.dirname(destDir));
    await parent.create(recursive: true);
    final staging = await parent.createTemp('.$tmpPrefix');
    final download = File('${staging.path}.zip');
    final backup = Directory(
      p.join(parent.path, '.${p.basename(destDir)}.xcross-backup'),
    );
    try {
      await _restoreBackupIfNeeded(destDir, backup);
      await Downloader.downloadToFile(
        url,
        download,
        maxAttempts: 5,
        label: label,
      );
      await Log.logStep(
        'Extracting $label',
        () => extractFileToDisk(download.path, staging.path),
      );
      final extracted = Directory(
        extractedSubdirectory == null
            ? staging.path
            : p.join(staging.path, extractedSubdirectory),
      );
      if (!requiredFiles.every((relative) {
            final file = File(p.join(extracted.path, relative));
            return file.existsSync() && file.lengthSync() > 0;
          }) ||
          !requiredDirectories.every(
            (relative) =>
                Directory(p.join(extracted.path, relative)).existsSync(),
          )) {
        throw FlutterBuildError(
          '$label archive for engine $revision is incomplete.',
        );
      }
      await File(
        p.join(extracted.path, _revisionStampName),
      ).writeAsString('$revision\n', flush: true);

      final destination = Directory(destDir);
      if (destination.existsSync()) await destination.rename(backup.path);
      try {
        await extracted.rename(destDir);
      } on Object {
        if (backup.existsSync() && !Directory(destDir).existsSync()) {
          await backup.rename(destDir);
        }
        rethrow;
      }
      if (backup.existsSync()) await backup.delete(recursive: true);
    } finally {
      if (download.existsSync()) await download.delete();
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  static Future<void> _restoreBackupIfNeeded(
    String destination,
    Directory backup,
  ) async {
    if (!backup.existsSync()) return;
    if (Directory(destination).existsSync()) {
      await backup.delete(recursive: true);
      return;
    }
    await backup.rename(destination);
  }

  /// Platform-specific engine cache directory name.
  /// Mirrors `_HostArtifacts` in flutter_tools.
  static String get _hostEngineCacheDir => switch (true) {
    _ when Platform.isLinux =>
      Abi.current() == Abi.linuxArm64 ? 'linux-arm64' : 'linux-x64',
    _ when Platform.isMacOS =>
      Abi.current() == Abi.macosArm64 ? 'darwin-arm64' : 'darwin-x64',
    // No arm64 Windows engine variant is published.
    _ when Platform.isWindows => 'windows-x64',
    _ => 'linux-x64',
  };
}
