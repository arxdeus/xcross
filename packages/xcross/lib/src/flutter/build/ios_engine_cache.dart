import 'package:archive/archive_io.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

/// Resolves Flutter iOS engine artifacts needed for a debug iOS bundle.
///
/// On macOS, `flutter precache --ios` downloads these into
/// `bin/cache/artifacts/engine/ios/`. On Linux, Flutter skips iOS artifacts,
/// so we fetch them ourselves from `storage.googleapis.com`. Missing artifacts
/// are stored outside the Flutter SDK so read-only installations work.
final class IosEngineCache<T extends PlatformHostInterface> {
  IosEngineCache({
    required this.targetPolicy,
    required this.hostTools,
    required this.flutterRoot,
    String? cacheRoot,
  }) : cacheRoot =
           cacheRoot ??
           p.join(
             targetPolicy.target.host.paths.cacheRoot,
             'xcross',
             'flutter-engine',
           ) {
    hostTools.artifactPlatform;
  }
  IosTarget<T> get target => targetPolicy.target;
  T get host => target.host;
  final String flutterRoot;
  final String cacheRoot;
  final NativeHostTools<T> hostTools;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  String get hostArtifactPlatform => hostTools.artifactPlatform;
  String get hostEngineCacheDirectory => hostTools.engineCacheDirectory;

  String get hostArtifactsUrl =>
      '$flutterArtifactBaseUrl/$engineHash/$hostArtifactPlatform/artifacts.zip';

  String get _flutterSdkEngineRoot =>
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine');

  String get engineHash => _readEngineHash();

  String get _userEngineRoot =>
      p.join(cacheRoot, engineHash, 'artifacts', 'engine');

  /// Directory containing the debug/JIT iOS engine artifacts.
  String get _engineDir {
    final flutterSdkDirectory = p.join(_flutterSdkEngineRoot, 'ios');
    final flutterFramework = p.join(flutterSdkDirectory, 'Flutter.xcframework');
    if (host.fileSystem.directory(flutterFramework).existsSync()) {
      return flutterSdkDirectory;
    }

    return p.join(_userEngineRoot, 'ios');
  }

  /// Flutter.xcframework inside [_engineDir].
  String get flutterXcframework => p.join(_engineDir, 'Flutter.xcframework');

  String flutterSlice(String xcframework) {
    final identifiers = targetPolicy.engineSliceIdentifiers;
    for (final identifier in identifiers) {
      final slice = p.join(xcframework, identifier);
      if (host.fileSystem
          .directory(p.join(slice, 'Flutter.framework'))
          .existsSync()) {
        return slice;
      }
    }
    throw FlutterBuildError(
      'Flutter ARM64 ${target.buildPlatform.platformName} slice missing in $xcframework',
    );
  }

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
      hostEngineCacheDirectory,
    );
    final hasSnapshotData =
        host.fileSystem
            .file(p.join(flutterSdkDirectory, 'vm_isolate_snapshot.bin'))
            .existsSync() &&
        host.fileSystem
            .file(p.join(flutterSdkDirectory, 'isolate_snapshot.bin'))
            .existsSync();
    if (hasSnapshotData) return flutterSdkDirectory;

    return p.join(_userEngineRoot, hostArtifactPlatform);
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
      if (host.fileSystem.file(candidate).existsSync()) return candidate;
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
    if (host.fileSystem.directory(flutterSdkDirectory).existsSync()) {
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
      final file = host.fileSystem.file(p.join(flutterRoot, rel));
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
    if (!host.fileSystem.directory(flutterXcframework).existsSync()) {
      await _downloadIosArtifacts();
    }
    flutterSlice(flutterXcframework);
    if (!host.fileSystem.file(vmSnapshotData).existsSync() ||
        !host.fileSystem.file(isolateSnapshotData).existsSync()) {
      await _downloadHostArtifacts();
    }
    if (!host.fileSystem.directory(patchedSdkRoot).existsSync()) {
      await _downloadPatchedSdk();
    }
  }

  Future<void> _downloadHostArtifacts() async {
    final url = hostArtifactsUrl;
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
  Future<void> _fetchAndExtract(
    String url,
    String destDir,
    String tmpPrefix, {
    required String label,
  }) async {
    await host.fileSystem.directory(destDir).create(recursive: true);
    final tmp = await host.fileSystem
        .directory(host.paths.temporaryRoot)
        .createTemp(tmpPrefix);
    final zipPath = p.join(tmp.path, 'artifacts.zip');
    await Downloader.downloadToFile(
      url,
      host.fileSystem.file(zipPath),
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
}
