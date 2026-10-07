import 'dart:convert';
import 'dart:typed_data';

import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/host/shared/flutter/engine_archive_writer.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/constants.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

/// Resolves Flutter iOS engine artifacts needed for a debug iOS bundle.
///
/// On macOS, `flutter precache --ios` downloads these into
/// `bin/cache/artifacts/engine/ios/`. On Linux, Flutter skips iOS artifacts,
/// so we fetch them ourselves from `storage.googleapis.com`. Missing artifacts
/// are stored outside the Flutter SDK so read-only installations work.
///
/// Artifacts inside the Flutter SDK are only reused when they belong to the
/// SDK's current engine revision. On non-macOS hosts flutter_tools never
/// refreshes `artifacts/engine/ios` after an upgrade, so a one-off
/// `flutter precache --ios` leaves an engine behind that rejects every kernel
/// the upgraded frontend_server produces ("Invalid SDK hash").
@internal
final class IosEngineCache<T extends PlatformHostInterface> {
  IosEngineCache({
    required this.log,
    required this.downloader,
    required this.targetPolicy,
    required this.hostTools,
    required this.flutterRoot,
    String? cacheRoot,
  }) : cacheRoot =
           cacheRoot ??
           targetPolicy.target.host.paths.context.join(
             targetPolicy.target.host.paths.cacheRoot,
             'xcross',
             'flutter-engine',
           ) {
    if (!identical(target.host, hostTools.host)) {
      throw ArgumentError('Engine cache requires one coherent host instance');
    }
    hostTools.artifactPlatform;
  }
  IosTarget<T> get target => targetPolicy.target;
  T get host => target.host;
  final Log log;
  final Downloader downloader;
  final String flutterRoot;
  final String cacheRoot;
  final NativeHostTools<T> hostTools;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  String get hostArtifactPlatform => hostTools.artifactPlatform;
  String get hostEngineCacheDirectory => hostTools.engineCacheDirectory;

  String get hostArtifactsUrl =>
      '$flutterArtifactBaseUrl/$engineHash/$hostArtifactPlatform/artifacts.zip';

  String get _flutterSdkEngineRoot => host.paths.context.join(
    flutterRoot,
    'bin',
    'cache',
    'artifacts',
    'engine',
  );

  String get engineHash => _readEngineHash();

  String get _userEngineRoot =>
      host.paths.context.join(cacheRoot, engineHash, 'artifacts', 'engine');

  /// Directory containing the debug/JIT iOS engine artifacts.
  String get _engineDir {
    if (_sdkIosEngineUsable) return _flutterSdkIosEngineDir;

    return host.paths.context.join(
      _userEngineRoot,
      targetPolicy.engineArtifact,
    );
  }

  String get _flutterSdkIosEngineDir => host.paths.context.join(
    _flutterSdkEngineRoot,
    targetPolicy.engineArtifact,
  );

  bool get _sdkIosEngineUsable {
    final directory = _flutterSdkIosEngineDir;
    final framework = host.paths.context.join(directory, 'Flutter.xcframework');
    return host.fileSystem.directory(framework).existsSync() &&
        _preservesCase(directory) &&
        !_isStale(sdkIosEngineRevision);
  }

  /// Engine revision of the iOS artifacts inside the Flutter SDK, or `null`
  /// when nothing records one.
  ///
  /// The framework's own `Info.plist` (`FlutterEngine`) is authoritative,
  /// since it travels with the binary. `bin/cache/ios-sdk.stamp`, written by
  /// `flutter precache --ios`, is the fallback.
  @visibleForTesting
  String? get sdkIosEngineRevision =>
      _frameworkEngineRevision(
        host.paths.context.join(_flutterSdkIosEngineDir, 'Flutter.xcframework'),
      ) ??
      _readStamp('ios-sdk');

  /// Engine revision of the host snapshots and patched SDK inside the
  /// Flutter SDK, from `bin/cache/flutter_sdk.stamp`.
  @visibleForTesting
  String? get sdkCommonEngineRevision => _readStamp('flutter_sdk');

  /// Stale only on positive evidence: an SDK artifact without any recorded
  /// revision stays usable, as it always was.
  bool _isStale(String? revision) {
    if (revision == null) return false;
    try {
      return revision != engineHash;
    } on FlutterBuildError {
      return false;
    }
  }

  String? _frameworkEngineRevision(String xcframework) {
    final context = host.paths.context;
    for (final identifier in targetPolicy.engineSliceIdentifiers) {
      final plist = host.fileSystem.file(
        context.join(
          xcframework,
          identifier,
          'Flutter.framework',
          'Info.plist',
        ),
      );
      if (!plist.existsSync()) continue;
      try {
        final bytes = plist.readAsBytesSync();
        final binary = _isBinaryPlist(bytes);
        // The XML reader prints a stack trace for malformed input, so only
        // hand it something that could carry the key.
        if (!binary && !utf8.decode(bytes).contains('FlutterEngine')) {
          return null;
        }
        final decoded = binary
            ? PropertyListSerialization.propertyListWithData(
                ByteData.sublistView(bytes),
              )
            : PropertyListSerialization.propertyListWithString(
                utf8.decode(bytes),
              );
        if (decoded case {
          'FlutterEngine': final String revision,
        } when revision.trim().isNotEmpty) {
          return revision.trim();
        }
      } on Object {
        // Unreadable or malformed plist: no evidence either way.
      }
      return null;
    }
    return null;
  }

  static bool _isBinaryPlist(Uint8List bytes) =>
      bytes.length >= 8 && ascii.decode(bytes.sublist(0, 8)) == 'bplist00';

  String? _readStamp(String name) {
    final file = host.fileSystem.file(
      host.paths.context.join(flutterRoot, 'bin', 'cache', '$name.stamp'),
    );
    try {
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } on Object {
      return null;
    }
  }

  bool _preservesCase(String engineDirectory) {
    final context = host.paths.context;
    final xcframework = context.join(engineDirectory, 'Flutter.xcframework');
    if (!_entryNames(engineDirectory).contains('Flutter.xcframework')) {
      return false;
    }
    final slices = _entryNames(xcframework);
    for (final identifier in targetPolicy.engineSliceIdentifiers) {
      if (!slices.contains(identifier)) continue;
      final slice = context.join(xcframework, identifier);
      if (!_entryNames(slice).contains('Flutter.framework')) return false;
      final framework = _entryNames(context.join(slice, 'Flutter.framework'));
      return framework.contains('Flutter') && framework.contains('Info.plist');
    }
    return true;
  }

  Set<String> _entryNames(String path) {
    final directory = host.fileSystem.directory(path);
    if (!directory.existsSync()) return const {};
    return {
      for (final entity in directory.listSync(followLinks: false))
        host.paths.context.basename(entity.path),
    };
  }

  /// Flutter.xcframework inside [_engineDir].
  String get flutterXcframework =>
      host.paths.context.join(_engineDir, 'Flutter.xcframework');

  String flutterSlice(String xcframework) {
    final identifiers = targetPolicy.engineSliceIdentifiers;
    for (final identifier in identifiers) {
      final slice = host.paths.context.join(xcframework, identifier);
      if (host.fileSystem
          .directory(host.paths.context.join(slice, 'Flutter.framework'))
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
      host.paths.context.join(_hostEngineDir, 'vm_isolate_snapshot.bin');

  /// `isolate_snapshot.bin` from the host engine cache.
  String get isolateSnapshotData =>
      host.paths.context.join(_hostEngineDir, 'isolate_snapshot.bin');

  /// Directory containing snapshot data for the host Dart engine.
  String get _hostEngineDir {
    final flutterSdkDirectory = host.paths.context.join(
      _flutterSdkEngineRoot,
      hostEngineCacheDirectory,
    );
    final hasSnapshotData =
        !_isStale(sdkCommonEngineRevision) &&
        host.fileSystem
            .file(
              host.paths.context.join(
                flutterSdkDirectory,
                'vm_isolate_snapshot.bin',
              ),
            )
            .existsSync() &&
        host.fileSystem
            .file(
              host.paths.context.join(
                flutterSdkDirectory,
                'isolate_snapshot.bin',
              ),
            )
            .existsSync();
    if (hasSnapshotData) return flutterSdkDirectory;

    return host.paths.context.join(_userEngineRoot, hostArtifactPlatform);
  }

  /// Path to the Dart frontend_server snapshot. Prefers the AOT variant
  /// (`frontend_server_aot.dart.snapshot`) for speed; falls back to the JIT
  /// variant.
  String get frontendServer {
    final snapshotsDir = host.paths.context.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      'snapshots',
    );
    const jitSnapshot = 'frontend_server.dart.snapshot';
    for (final name in ['frontend_server_aot.dart.snapshot', jitSnapshot]) {
      final candidate = host.paths.context.join(snapshotsDir, name);
      if (host.fileSystem.file(candidate).existsSync()) return candidate;
    }
    // Canonical fallback — used in error messages even if the file is missing.
    return host.paths.context.join(snapshotsDir, jitSnapshot);
  }

  /// Patched SDK platform .dill — debug uses `flutter_patched_sdk/`.
  String get patchedSdkRoot {
    final flutterSdkDirectory = host.paths.context.join(
      _flutterSdkEngineRoot,
      'common',
      'flutter_patched_sdk',
    );
    if (!_isStale(sdkCommonEngineRevision) &&
        host.fileSystem.directory(flutterSdkDirectory).existsSync()) {
      return flutterSdkDirectory;
    }

    return host.paths.context.join(
      _userEngineRoot,
      'common',
      'flutter_patched_sdk',
    );
  }

  /// Reads the engine hash that pins the artifact set.
  String _readEngineHash() {
    for (final rel in [
      host.paths.context.join('bin', 'internal', 'engine.version'),
      host.paths.context.join('bin', 'cache', 'engine.stamp'),
    ]) {
      final file = host.fileSystem.file(
        host.paths.context.join(flutterRoot, rel),
      );
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
    _warnAboutStaleSdkArtifacts();
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

  /// Explain, once per build, why the SDK's own artifacts were passed over,
  /// and flag a Dart SDK whose frontend_server would emit kernel the engine
  /// rejects.
  void _warnAboutStaleSdkArtifacts() {
    final hash = engineHash;
    final ios = sdkIosEngineRevision;
    if (_isStale(ios) &&
        host.fileSystem
            .directory(
              host.paths.context.join(
                _flutterSdkIosEngineDir,
                'Flutter.xcframework',
              ),
            )
            .existsSync()) {
      log.logWarn(
        'Flutter SDK iOS engine artifacts are from engine $ios, but the SDK '
        'expects $hash. Using engine $hash artifacts cached by xcross instead. '
        'To refresh the SDK copy, run `flutter precache --ios --force`.',
      );
    }
    final common = sdkCommonEngineRevision;
    if (_isStale(common)) {
      log.logWarn(
        'Flutter SDK host engine artifacts are from engine $common, but the '
        'SDK expects $hash. Using engine $hash artifacts cached by xcross '
        'instead. Run `flutter precache --force` to refresh the SDK cache.',
      );
    }
    final dartSdk = _readStamp('engine-dart-sdk');
    if (_isStale(dartSdk)) {
      log.logWarn(
        'Flutter Dart SDK is from engine $dartSdk, but the SDK expects $hash. '
        'Kernel it compiles may fail to load with "Invalid SDK hash". '
        'Run `flutter precache --force` to refresh it.',
      );
    }
  }

  Future<void> _downloadHostArtifacts() async {
    final url = hostArtifactsUrl;
    log.logTrace('downloading Flutter host engine artifacts from $url');
    await _fetchAndExtract(
      url,
      _hostEngineDir,
      'host-artifacts-',
      label: 'Flutter host engine',
    );
  }

  Future<void> _downloadIosArtifacts() async {
    final hash = _readEngineHash();
    final url =
        '$flutterArtifactBaseUrl/$hash/${targetPolicy.engineArtifact}/artifacts.zip';
    log.logTrace('downloading Flutter iOS engine artifacts from $url');
    await _fetchAndExtract(
      url,
      _engineDir,
      'ios-artifacts-',
      label: 'Flutter iOS engine',
    );
  }

  Future<void> _downloadPatchedSdk() async {
    final hash = _readEngineHash();
    final leaf = host.paths.context.basename(patchedSdkRoot);
    final url = '$flutterArtifactBaseUrl/$hash/$leaf.zip';
    log.logTrace('downloading Flutter patched SDK from $url');
    await _fetchAndExtract(
      url,
      host.paths.context.dirname(patchedSdkRoot),
      'patched-sdk-',
      label: 'Flutter patched SDK',
    );
  }

  /// Download [url] into a temp directory, extract into [destDir], then
  /// delete the temp directory.
  ///
  /// Pure Dart — no `curl`/`unzip` subprocess. The download follows redirects
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
    final zipPath = host.paths.context.join(tmp.path, 'artifacts.zip');
    try {
      await downloader.downloadToFile(
        url,
        host.fileSystem.file(zipPath),
        maxAttempts: 5,
        label: label,
      );
      await log.logStep(
        'Extracting $label',
        () => FlutterEngineArchiveWriter(host).extractZip(zipPath, destDir),
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  }
}
