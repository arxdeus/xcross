import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/util/download.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Resolves Flutter iOS engine artifacts needed for a debug iOS bundle.
///
/// On macOS, `flutter precache --ios` downloads these into
/// `bin/cache/artifacts/engine/ios/`. On Linux, Flutter skips iOS artifacts,
/// so we fetch them ourselves from `storage.googleapis.com`.
class IosEngineCache {
  final String flutterRoot;

  IosEngineCache({required this.flutterRoot});

  /// `bin/cache/artifacts/engine/ios/` — debug/JIT artifacts only.
  String get _engineDir =>
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine', 'ios');

  /// Flutter.xcframework inside [_engineDir].
  String get flutterXcframework => p.join(_engineDir, 'Flutter.xcframework');

  /// `vm_isolate_snapshot.bin` from the host engine cache.
  String get vmSnapshotData => p.join(_hostEngineDir, 'vm_isolate_snapshot.bin');

  /// `isolate_snapshot.bin` from the host engine cache.
  String get isolateSnapshotData =>
      p.join(_hostEngineDir, 'isolate_snapshot.bin');

  /// Host engine cache dir — where Flutter caches the host Dart engine.
  String get _hostEngineDir => p.join(
      flutterRoot, 'bin', 'cache', 'artifacts', 'engine', _hostEngineCacheDir);

  /// Path to the Dart frontend_server snapshot. Prefers the AOT variant
  /// (`frontend_server_aot.dart.snapshot`) for speed; falls back to the JIT
  /// variant.
  String get frontendServer {
    final snapshotsDir =
        p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'snapshots');
    for (final name in [
      'frontend_server_aot.dart.snapshot',
      'frontend_server.dart.snapshot',
    ]) {
      final candidate = p.join(snapshotsDir, name);
      if (File(candidate).existsSync()) return candidate;
    }
    // Canonical fallback — used in error messages even if the file is missing.
    return p.join(snapshotsDir, 'frontend_server.dart.snapshot');
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

  /// Engine hash that pins the artifact set. Read from
  /// `bin/internal/engine.version` (stable/beta) or `bin/cache/engine.stamp`
  /// (written by flutter_tools at runtime).
  Future<String> _engineHash() async {
    for (final rel in [
      p.join('bin', 'internal', 'engine.version'),
      p.join('bin', 'cache', 'engine.stamp'),
    ]) {
      final file = File(p.join(flutterRoot, rel));
      if (file.existsSync()) {
        final text = (await file.readAsString()).trim();
        if (text.isNotEmpty) return text;
      }
    }
    throw XcrossError(
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
    final hash = await _engineHash();
    final url =
        '$flutterArtifactBaseUrl/$hash/$_hostEngineCacheDir/artifacts.zip';
    logStatus('[curl] downloading Flutter host engine artifacts from $url');
    await _fetchAndExtract(url, _hostEngineDir, 'host-artifacts-');
  }

  Future<void> _downloadIosArtifacts() async {
    final hash = await _engineHash();
    final url = '$flutterArtifactBaseUrl/$hash/ios/artifacts.zip';
    logStatus('[curl] downloading Flutter iOS engine artifacts from $url');
    await _fetchAndExtract(url, _engineDir, 'ios-artifacts-');
  }

  Future<void> _downloadPatchedSdk() async {
    final hash = await _engineHash();
    final leaf = p.basename(patchedSdkRoot);
    final url = '$flutterArtifactBaseUrl/$hash/$leaf.zip';
    logStatus('[curl] downloading Flutter patched SDK from $url');
    await _fetchAndExtract(url, p.dirname(patchedSdkRoot), 'patched-sdk-');
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
    String tmpPrefix,
  ) async {
    await Directory(destDir).create(recursive: true);
    final tmp = await Directory.systemTemp.createTemp(tmpPrefix);
    final zipPath = p.join(tmp.path, 'artifacts.zip');
    await downloadToFile(url, File(zipPath), maxAttempts: 5);
    await extractFileToDisk(zipPath, destDir);
    await tmp.delete(recursive: true);
  }

  /// Platform-specific engine cache directory name.
  /// Mirrors `_HostArtifacts` in flutter_tools.
  static String get _hostEngineCacheDir {
    if (Platform.isLinux) {
      // Dart doesn't expose CPU arch directly; fall back to env vars.
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ??
          Platform.environment['HOSTTYPE'] ??
          '';
      return (arch.contains('arm') || arch.contains('aarch64'))
          ? 'linux-arm64'
          : 'linux-x64';
    }
    if (Platform.isMacOS) {
      // Dart 3+ embeds "arm64" in Platform.version on Apple Silicon.
      final isArm = Platform.version.contains('arm64') ||
          (Platform.environment['HOSTTYPE'] ?? '').contains('arm64');
      return isArm ? 'darwin-arm64' : 'darwin-x64';
    }
    // No arm64 Windows engine variant is published.
    if (Platform.isWindows) {
      return 'windows-x64';
    }
    return 'linux-x64';
  }
}
