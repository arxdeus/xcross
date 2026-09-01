import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Resolves Flutter iOS engine artifacts needed for a debug iOS bundle.
///
/// On macOS, `flutter precache --ios` downloads these into
/// `bin/cache/artifacts/engine/ios/`. On Linux, Flutter skips iOS artifacts,
/// so we fetch them ourselves from `storage.googleapis.com`. Missing artifacts
/// are stored outside the Flutter SDK so read-only installations work.
final class IosEngineCache {
  IosEngineCache({required this.flutterRoot, String? cacheRoot})
    : cacheRoot = cacheRoot ?? _defaultCacheRoot;

  final String flutterRoot;
  final String cacheRoot;

  String get _flutterSdkEngineRoot =>
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine');

  String get engineHash => _readEngineHash();

  String get _userEngineRoot =>
      p.join(cacheRoot, engineHash, 'artifacts', 'engine');

  /// Directory containing the debug/JIT iOS engine artifacts.
  String get _engineDir {
    final flutterSdkDirectory = p.join(_flutterSdkEngineRoot, 'ios');
    final flutterFramework = p.join(flutterSdkDirectory, 'Flutter.xcframework');
    if (Directory(flutterFramework).existsSync()) return flutterSdkDirectory;

    return p.join(_userEngineRoot, 'ios');
  }

  /// Flutter.xcframework inside [_engineDir].
  String get flutterXcframework => p.join(_engineDir, 'Flutter.xcframework');

  /// `vm_isolate_snapshot.bin` from the host engine cache.
  String get vmSnapshotData =>
      p.join(_hostEngineDir, 'vm_isolate_snapshot.bin');

  /// `isolate_snapshot.bin` from the host engine cache.
  String get isolateSnapshotData =>
      p.join(_hostEngineDir, 'isolate_snapshot.bin');

  /// Directory containing snapshot data for the host Dart engine.
  String get _hostEngineDir {
    final flutterSdkDirectory = p.join(
      _flutterSdkEngineRoot,
      _hostEngineCacheDir,
    );
    final hasSnapshotData =
        File(
          p.join(flutterSdkDirectory, 'vm_isolate_snapshot.bin'),
        ).existsSync() &&
        File(p.join(flutterSdkDirectory, 'isolate_snapshot.bin')).existsSync();
    if (hasSnapshotData) return flutterSdkDirectory;

    return p.join(_userEngineRoot, _hostEngineCacheDir);
  }

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
  String get patchedSdkRoot {
    final flutterSdkDirectory = p.join(
      _flutterSdkEngineRoot,
      'common',
      'flutter_patched_sdk',
    );
    if (Directory(flutterSdkDirectory).existsSync()) {
      return flutterSdkDirectory;
    }

    return p.join(_userEngineRoot, 'common', 'flutter_patched_sdk');
  }

  /// Reads the engine hash that pins the artifact set.
  String _readEngineHash() {
    for (final rel in [
      p.join('bin', 'internal', 'engine.version'),
      p.join('bin', 'cache', 'engine.stamp'),
    ]) {
      final file = File(p.join(flutterRoot, rel));
      if (file.existsSync()) {
        final text = file.readAsStringSync().trim();
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

  /// Verify required iOS engine artifacts are present, downloading each set
  /// from `storage.googleapis.com` if missing. Safe to call repeatedly.
  Future<void> ensureArtifactsAvailable() async {
    if (!Directory(flutterXcframework).existsSync()) {
      await _downloadIosArtifacts();
    }
    if (!File(vmSnapshotData).existsSync() ||
        !File(isolateSnapshotData).existsSync()) {
      await _downloadHostArtifacts();
    }
    if (!Directory(patchedSdkRoot).existsSync()) {
      await _downloadPatchedSdk();
    }
  }

  Future<void> _downloadHostArtifacts() async {
    final hash = _readEngineHash();
    final url =
        '$flutterArtifactBaseUrl/$hash/$_hostEngineCacheDir/artifacts.zip';
    Log.logTrace('downloading Flutter host engine artifacts from $url');
    await _fetchAndExtract(
      url,
      _hostEngineDir,
      'host-artifacts-',
      label: 'Flutter host engine',
    );
  }

  Future<void> _downloadIosArtifacts() async {
    final hash = _readEngineHash();
    final url = '$flutterArtifactBaseUrl/$hash/ios/artifacts.zip';
    Log.logTrace('downloading Flutter iOS engine artifacts from $url');
    await _fetchAndExtract(
      url,
      _engineDir,
      'ios-artifacts-',
      label: 'Flutter iOS engine',
    );
  }

  Future<void> _downloadPatchedSdk() async {
    final hash = _readEngineHash();
    final leaf = p.basename(patchedSdkRoot);
    final url = '$flutterArtifactBaseUrl/$hash/$leaf.zip';
    Log.logTrace('downloading Flutter patched SDK from $url');
    await _fetchAndExtract(
      url,
      p.dirname(patchedSdkRoot),
      'patched-sdk-',
      label: 'Flutter patched SDK',
    );
  }

  /// Download [url] into a temp directory, extract into [destDir], then
  /// delete the temp directory.
  ///
  /// Pure Dart — no `curl`/`unzip` subprocess. The download follows redirects
  /// and retries transient failures; the archive package's posix-aware
  /// extractor restores unix permissions (exec bits) and symlinks.
  static Future<void> _fetchAndExtract(
    String url,
    String destDir,
    String tmpPrefix, {
    required String label,
  }) async {
    await Directory(destDir).create(recursive: true);
    final tmp = await Directory.systemTemp.createTemp(tmpPrefix);
    final zipPath = p.join(tmp.path, 'artifacts.zip');
    await Downloader.downloadToFile(
      url,
      File(zipPath),
      maxAttempts: 5,
      label: label,
    );
    // Unzipping hundreds of MB is slow enough to look like a hang on its own.
    await Log.logStep(
      'Extracting $label',
      () => extractFileToDisk(zipPath, destDir),
    );
    await tmp.delete(recursive: true);
  }

  /// Per-user directory for artifacts missing from the Flutter SDK.
  static String get _defaultCacheRoot {
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return p.join(localAppData, 'xcross', 'flutter-engine');
      }
    }
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return p.join(xdg, 'xcross', 'flutter-engine');
    }
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.cache', 'xcross', 'flutter-engine');
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
