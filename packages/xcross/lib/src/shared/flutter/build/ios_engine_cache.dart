import 'dart:convert';
import 'dart:io';
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
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

/// Resolves Flutter iOS engine artifacts needed for a debug iOS bundle.
///
/// Where flutter_tools manages them, `flutter precache --ios` downloads these
/// into `bin/cache/artifacts/engine/ios/`. Elsewhere Flutter skips iOS
/// artifacts, so we fetch them ourselves from `storage.googleapis.com`.
/// Missing artifacts are stored outside the Flutter SDK so read-only
/// installations work.
///
/// Artifacts inside the Flutter SDK are only reused when they belong to the
/// SDK's current engine revision. On hosts where flutter_tools does not
/// manage iOS artifacts (see
/// [NativeHostTools.flutterManagesIosEngineArtifacts]) it never refreshes
/// `artifacts/engine/ios` after an upgrade, so a one-off
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
    this.mode = FlutterBuildMode.debug,
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

  /// Build mode whose engine and platform kernel this cache provides.
  final FlutterBuildMode mode;

  /// Engine artifact directory for [mode]: the target's JIT engine in debug,
  /// the device AOT engine (`ios-release`, `ios-profile`) otherwise.
  String get engineArtifact =>
      mode.isPrecompiled ? mode.engineArtifact : targetPolicy.engineArtifact;
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

  /// The [engineArtifact] directory a build embeds `Flutter.xcframework`
  /// from: the Flutter SDK's copy when it matches the engine, else the
  /// xcross cache. On macOS it also holds the `gen_snapshot_arm64` that
  /// compiles for that engine.
  String get engineDirectory {
    if (_sdkIosEngineUsable) return _flutterSdkIosEngineDir;

    return host.paths.context.join(_userEngineRoot, engineArtifact);
  }

  String get _flutterSdkIosEngineDir =>
      host.paths.context.join(_flutterSdkEngineRoot, engineArtifact);

  bool get _sdkIosEngineUsable {
    final directory = _flutterSdkIosEngineDir;
    final framework = host.paths.context.join(directory, 'Flutter.xcframework');
    final hasFramework = host.fileSystem.directory(framework).existsSync();
    if (!hasFramework || !_preservesCase(directory)) {
      return false;
    }
    final revision = sdkIosEngineRevision;
    // When Flutter does not keep this directory current, only positive
    // evidence that it matches the engine is good enough.
    if (!_flutterManagesIosArtifacts) return _matchesEngine(revision);
    return !_isStale(revision);
  }

  bool get _flutterManagesIosArtifacts =>
      hostTools.flutterManagesIosEngineArtifacts;

  /// Engine revision of the iOS artifacts inside the Flutter SDK, or `null`
  /// when nothing records one.
  ///
  /// The framework's own `Info.plist` (`FlutterEngine`) is authoritative,
  /// since it travels with the binary. Where flutter_tools keeps the
  /// directory current, `bin/cache/ios-sdk.stamp` is the fallback.
  @visibleForTesting
  String? get sdkIosEngineRevision =>
      _frameworkInfoString(
        host.paths.context.join(_flutterSdkIosEngineDir, 'Flutter.xcframework'),
        'FlutterEngine',
      ) ??
      (_flutterManagesIosArtifacts ? _readStamp('ios-sdk') : null);

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

  bool _matchesEngine(String? revision) {
    if (revision == null) return false;
    try {
      return revision == engineHash;
    } on FlutterBuildError {
      return false;
    }
  }

  /// `MinimumOSVersion` of the engine's `Flutter.framework`, or `null` when
  /// its `Info.plist` records none.
  String? get engineMinimumOsVersion =>
      _frameworkInfoString(flutterXcframework, 'MinimumOSVersion');

  /// The string [key] of the first engine slice's `Flutter.framework`
  /// `Info.plist` in [xcframework], or `null` when it is absent or empty.
  String? _frameworkInfoString(String xcframework, String key) {
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
        if (!binary && !utf8.decode(bytes).contains(key)) {
          return null;
        }
        final decoded = binary
            ? PropertyListSerialization.propertyListWithData(
                ByteData.sublistView(bytes),
              )
            : PropertyListSerialization.propertyListWithString(
                utf8.decode(bytes),
              );
        final value = decoded is Map ? decoded[key] : null;
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
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

  /// Flutter.xcframework inside [engineDirectory].
  String get flutterXcframework =>
      host.paths.context.join(engineDirectory, 'Flutter.xcframework');

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

  /// Host `impellerc`, from the same host archive as the snapshot data.
  String get impellerc => host.paths.context.join(
    _hostEngineDir,
    host.paths.executableName('impellerc'),
  );

  /// `shader_lib` include directory shipped next to [impellerc].
  String get shaderLib => host.paths.context.join(_hostEngineDir, 'shader_lib');

  /// Host `font-subset`, from the host `font-subset.zip`.
  String get fontSubset => host.paths.context.join(
    _fontSubsetDir,
    host.paths.executableName('font-subset'),
  );

  /// `const_finder.dart.snapshot`, shipped with [fontSubset].
  String get constFinder =>
      host.paths.context.join(_fontSubsetDir, 'const_finder.dart.snapshot');

  /// The Flutter SDK's `dart`, which runs [constFinder] as flutter_tools does.
  String get dart => host.paths.context.join(
    flutterRoot,
    'bin',
    'cache',
    'dart-sdk',
    'bin',
    host.paths.executableName('dart'),
  );

  /// Directory containing snapshot data for the host Dart engine.
  String get _hostEngineDir {
    final flutterSdkDirectory = host.paths.context.join(
      _flutterSdkEngineRoot,
      hostEngineCacheDirectory,
    );
    final hasHostArtifacts =
        !_isStale(sdkCommonEngineRevision) &&
        [
          'vm_isolate_snapshot.bin',
          'isolate_snapshot.bin',
          host.paths.executableName('impellerc'),
        ].every(
          (name) => host.fileSystem
              .file(host.paths.context.join(flutterSdkDirectory, name))
              .existsSync(),
        ) &&
        host.fileSystem
            .directory(
              host.paths.context.join(flutterSdkDirectory, 'shader_lib'),
            )
            .existsSync();
    if (hasHostArtifacts) return flutterSdkDirectory;

    return host.paths.context.join(_userEngineRoot, hostArtifactPlatform);
  }

  /// Directory holding `font-subset` and `const_finder.dart.snapshot`.
  ///
  /// flutter_tools keeps them in the host engine directory and records the
  /// engine in `font-subset.stamp`. xcross's own copy lives in a separate
  /// directory so it never mixes with the host archive.
  String get _fontSubsetDir {
    final flutterSdkDirectory = host.paths.context.join(
      _flutterSdkEngineRoot,
      hostEngineCacheDirectory,
    );
    final hasFontSubset =
        _matchesEngine(_readStamp('font-subset')) &&
        [
          host.paths.executableName('font-subset'),
          'const_finder.dart.snapshot',
        ].every(
          (name) => host.fileSystem
              .file(host.paths.context.join(flutterSdkDirectory, name))
              .existsSync(),
        );
    if (hasFontSubset) return flutterSdkDirectory;

    return host.paths.context.join(
      _userEngineRoot,
      'font-subset',
      hostArtifactPlatform,
    );
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
      mode.patchedSdk,
    );
    final sdkCommonIsCurrent = !_isStale(sdkCommonEngineRevision);
    if (sdkCommonIsCurrent &&
        host.fileSystem.directory(flutterSdkDirectory).existsSync()) {
      return flutterSdkDirectory;
    }

    return host.paths.context.join(_userEngineRoot, 'common', mode.patchedSdk);
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
    final hasHostArtifacts =
        host.fileSystem.file(vmSnapshotData).existsSync() &&
        host.fileSystem.file(isolateSnapshotData).existsSync() &&
        host.fileSystem.file(impellerc).existsSync() &&
        host.fileSystem.directory(shaderLib).existsSync();
    if (!hasHostArtifacts) {
      await _downloadHostArtifacts();
    }
    if (!host.fileSystem.directory(patchedSdkRoot).existsSync()) {
      await _downloadPatchedSdk();
    }
    _markUsed();
  }

  /// Name of the stamp `xcross cache prune` reads to tell a cache entry
  /// still in use from one left behind by an old Flutter version.
  static const lastUsedStamp = '.last_used';

  /// Best effort: only the cache under [cacheRoot] is stamped, never the
  /// Flutter SDK, and a read-only cache only costs prune accuracy.
  void _markUsed() {
    final root = host.paths.context.join(cacheRoot, engineHash);
    if (!host.fileSystem.directory(root).existsSync()) return;
    try {
      host.fileSystem
          .file(host.paths.context.join(root, lastUsedStamp))
          .writeAsStringSync(DateTime.now().toUtc().toIso8601String());
    } on FileSystemException {
      // Ignored on purpose.
    }
  }

  /// Make sure `font-subset` and `const_finder` are present, downloading the
  /// host `font-subset.zip` if needed. Only icon tree shaking needs them.
  Future<void> ensureFontSubsetAvailable() async {
    final present =
        host.fileSystem.file(fontSubset).existsSync() &&
        host.fileSystem.file(constFinder).existsSync();
    if (present) return;
    final url =
        '$flutterArtifactBaseUrl/$engineHash/$hostArtifactPlatform/font-subset.zip';
    log.logTrace('downloading Flutter font-subset from $url');
    await _fetchAndExtract(
      url,
      _fontSubsetDir,
      'font-subset-',
      label: 'Flutter font-subset',
    );
  }

  /// Explain why the SDK's own artifacts were passed over, and flag a Dart
  /// SDK whose frontend_server would emit kernel the engine rejects.
  ///
  /// Each warning is printed once per process: a build creates several
  /// engine caches and calls this from each of them.
  void _warnAboutStaleSdkArtifacts() {
    final String hash;
    try {
      hash = engineHash;
    } on FlutterBuildError {
      return; // The download below reports the missing engine hash.
    }
    final ios = sdkIosEngineRevision;
    final sdkIosFramework = host.paths.context.join(
      _flutterSdkIosEngineDir,
      'Flutter.xcframework',
    );
    if (_isStale(ios) &&
        host.fileSystem.directory(sdkIosFramework).existsSync()) {
      _warnOnce(
        'Flutter SDK iOS engine artifacts are from engine $ios, but the SDK '
        'is on engine $hash. xcross is using matching artifacts from its own '
        'cache instead. To refresh the SDK copy, run '
        '`flutter precache --ios --force`.',
      );
    }
    final common = sdkCommonEngineRevision;
    if (_isStale(common)) {
      _warnOnce(
        'Flutter SDK host engine artifacts are from engine $common, but the '
        'SDK is on engine $hash. xcross is using matching artifacts from its '
        'own cache instead. Run `flutter precache --force` to refresh the SDK.',
      );
    }
    final dartSdk = _readStamp('engine-dart-sdk');
    if (_isStale(dartSdk)) {
      _warnOnce(
        'Flutter Dart SDK is from engine $dartSdk, but the SDK is on engine '
        '$hash. The app may fail to start with "Invalid SDK hash". Run '
        '`flutter --version` to update the Dart SDK.',
      );
    }
  }

  void _warnOnce(String message) {
    if (_warned.add(message)) log.logWarn(message);
  }

  static final _warned = <String>{};

  @visibleForTesting
  static void resetWarningsForTesting() => _warned.clear();

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
    final url = '$flutterArtifactBaseUrl/$hash/$engineArtifact/artifacts.zip';
    log.logTrace('downloading Flutter iOS engine artifacts from $url');
    await _fetchAndExtract(
      url,
      engineDirectory,
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
