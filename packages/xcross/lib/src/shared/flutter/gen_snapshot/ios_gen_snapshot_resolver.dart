import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/file_system_inspection.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/engine_archive_writer.dart';
import 'package:xcross/src/host/shared/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/shared/config/config.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/flutter_sdk_release.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_manifest.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';

/// Where a resolved iOS AOT compiler came from.
@internal
enum IosGenSnapshotSource {
  /// Shipped with the Flutter SDK (macOS hosts).
  flutterSdk,

  /// A verified download reused from the xcross cache.
  cache,

  /// A compiler path the user pinned in xcross config.
  pinned,

  /// Downloaded from xcross_gen_snapshot by this resolution.
  download,
}

/// A resolved iOS AOT compiler (`gen_snapshot`).
@internal
final class IosGenSnapshot {
  const IosGenSnapshot({
    required this.executable,
    required this.mode,
    required this.release,
    required this.source,
  });

  /// Absolute path of the compiler executable.
  final String executable;
  final IosGenSnapshotMode mode;
  final FlutterSdkRelease release;
  final IosGenSnapshotSource source;
}

/// Finds the iOS AOT compiler that matches a Flutter SDK.
///
/// Flutter ships the iOS `gen_snapshot` for macOS only, so other hosts use
/// the compilers xcross_gen_snapshot builds from the Dart revision each
/// Flutter release pins. Resolution order:
///
/// 1. The compiler shipped with Flutter, where the host has one.
/// 2. A cached download whose `meta.json` matches and whose executable still
///    has the recorded SHA-256.
/// 3. A compiler the user pinned in xcross config (`ios_gen_snapshot`) for
///    the Flutter version or engine revision.
/// 4. A release of xcross_gen_snapshot tagged with the Flutter version whose
///    manifest names the same engine. The archive and the executable are
///    checked against the manifest digests before they are cached.
@internal
final class IosGenSnapshotResolver<T extends PlatformHostInterface> {
  IosGenSnapshotResolver({
    required this.hostPolicy,
    required this.runner,
    required this.downloader,
    required this.createHttpClient,
    required this.cacheRoot,
    this.pins = const {},
    this.releaseBaseUrl = defaultReleaseBaseUrl,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (!identical(hostPolicy.host, runner.host)) {
      throw ArgumentError('gen_snapshot resolution requires one host');
    }
  }

  static const repositoryUrl = 'https://github.com/arxdeus/xcross_gen_snapshot';
  static const defaultReleaseBaseUrl = '$repositoryUrl/releases/download';

  final IosGenSnapshotHost hostPolicy;
  final ProcessRunner<T> runner;
  final Downloader downloader;
  final http.Client Function() createHttpClient;

  /// The xcross cache root; compilers live under `gen-snapshot/`.
  final String cacheRoot;

  /// Pinned compilers keyed by Flutter version or engine revision.
  final Map<String, XcrossIosGenSnapshotPin> pins;
  final String releaseBaseUrl;
  final DateTime Function() _now;

  T get host => runner.host;
  Log get log => runner.log;

  /// Resolves the [mode] compiler for the Flutter SDK at [flutterRoot].
  Future<IosGenSnapshot> resolve({
    required String flutterRoot,
    required IosGenSnapshotMode mode,
  }) async {
    final shipped = hostPolicy.flutterCompiler(flutterRoot, mode);
    final release = FlutterSdkReleaseReader(host).read(flutterRoot);
    IosGenSnapshot result(String path, IosGenSnapshotSource source) =>
        IosGenSnapshot(
          executable: path,
          mode: mode,
          release: release,
          source: source,
        );

    if (shipped != null) {
      return result(shipped, IosGenSnapshotSource.flutterSdk);
    }
    final platform = hostPolicy.prebuiltPlatform;
    final cached = await cachedExecutable(release, mode, platform);
    if (cached != null) {
      final current = await _revalidate(cached, release, mode, platform);
      if (current != null) {
        _touch(cacheDirectory(release.engine, mode, platform));
        return result(current, IosGenSnapshotSource.cache);
      }
    }
    final pinned = await _pinned(release, mode);
    if (pinned != null) return result(pinned, IosGenSnapshotSource.pinned);
    final downloaded = await _download(release, mode, platform);
    return result(downloaded, IosGenSnapshotSource.download);
  }

  /// Where the [mode] compiler would come from, without downloading it.
  ///
  /// For `xcross flutter doctor`: `null` [IosGenSnapshotAvailability.source]
  /// means no compiler is available, and a network failure is reported
  /// rather than thrown, since the cache may still serve a later build.
  Future<IosGenSnapshotAvailability> availability({
    required String flutterRoot,
    required IosGenSnapshotMode mode,
  }) async {
    final FlutterSdkRelease release;
    try {
      final shipped = hostPolicy.flutterCompiler(flutterRoot, mode);
      if (shipped != null) {
        return IosGenSnapshotAvailability(
          source: IosGenSnapshotSource.flutterSdk,
          path: shipped,
        );
      }
      release = FlutterSdkReleaseReader(host).read(flutterRoot);
    } on FlutterBuildError catch (error) {
      return IosGenSnapshotAvailability(detail: error.message);
    }
    final platform = hostPolicy.prebuiltPlatform;
    final cached = await cachedExecutable(release, mode, platform);
    if (cached != null) {
      return IosGenSnapshotAvailability(
        source: IosGenSnapshotSource.cache,
        path: cached,
        release: release,
      );
    }
    final pin = [
      for (final key in [release.version, release.engine])
        ?pins[key]?.forMode(mode.name),
    ].firstOrNull;
    if (pin != null) {
      return IosGenSnapshotAvailability(
        source: IosGenSnapshotSource.pinned,
        path: pin,
        release: release,
      );
    }
    try {
      final manifest = await _fetchManifestOnce(release);
      final asset =
          manifest?.assets[IosGenSnapshotManifest.assetName(mode, platform)];
      if (manifest != null &&
          asset != null &&
          manifest.engine == release.engine) {
        return IosGenSnapshotAvailability(
          source: IosGenSnapshotSource.download,
          release: release,
        );
      }
      return IosGenSnapshotAvailability(
        release: release,
        detail:
            'No prebuilt compiler is published for Flutter '
            '${release.version} (engine ${release.shortEngine}) on '
            '$platform.',
      );
    } on IosGenSnapshotSchemaException catch (error) {
      return IosGenSnapshotAvailability(
        release: release,
        detail:
            'The published manifest uses schema ${error.schema}; run '
            '`xcross update`.',
      );
    } on Object catch (error) {
      return IosGenSnapshotAvailability(
        release: release,
        unknown: true,
        detail: 'Could not check $repositoryUrl: $error',
      );
    }
  }

  /// Cache directory for one engine, mode, and xcross_gen_snapshot platform.
  String cacheDirectory(
    String engine,
    IosGenSnapshotMode mode,
    String platform,
  ) => host.paths.context.join(
    cacheRoot,
    'gen-snapshot',
    engine,
    mode.name,
    platform,
  );

  String get _executableName => host.paths.executableName('gen_snapshot');

  /// The cached compiler, or `null` when it is absent, stale, or altered.
  @visibleForTesting
  Future<String?> cachedExecutable(
    FlutterSdkRelease release,
    IosGenSnapshotMode mode,
    String platform,
  ) async {
    final directory = cacheDirectory(release.engine, mode, platform);
    final executable = host.paths.context.join(directory, _executableName);
    final meta = host.fileSystem.file(
      host.paths.context.join(directory, 'meta.json'),
    );
    if (!meta.existsSync() || !host.fileSystem.file(executable).existsSync()) {
      return null;
    }
    try {
      final Object? document = jsonDecode(await meta.readAsString());
      if (document
          case {
            'engine': final String engine,
            'mode': final String cachedMode,
            'host': final String cachedHost,
            'executable_sha256': final String digest,
          }
          when engine == release.engine &&
              cachedMode == mode.name &&
              cachedHost == platform) {
        if (await _digest(executable) == digest.toLowerCase()) {
          return executable;
        }
        log.logWarn(
          'Cached iOS gen_snapshot at $executable does not match its '
          'recorded SHA-256; downloading it again.',
        );
      }
    } on FormatException {
      log.logTrace('Ignoring malformed ${meta.path}');
    } on FileSystemException catch (error) {
      log.logTrace('Ignoring unreadable gen_snapshot cache: $error');
    }
    return null;
  }

  Future<String?> _pinned(
    FlutterSdkRelease release,
    IosGenSnapshotMode mode,
  ) async {
    final pinned = [
      for (final key in [release.version, release.engine])
        if (pins[key]?.forMode(mode.name) case final path?) (key, path),
    ].firstOrNull;
    if (pinned == null) return null;
    final (key, path) = pinned;
    String problem(String detail) =>
        'The iOS ${mode.name} gen_snapshot pinned in xcross config '
        '(ios_gen_snapshot.$key.${mode.name}) $detail: $path';
    if (!host.fileSystem.file(path).existsSync()) {
      throw FlutterBuildError(problem('does not exist'));
    }
    final CapturedProcess check;
    try {
      check = await runner.run(path, const [
        '--version',
      ], timeout: const Duration(seconds: 30));
    } on Object catch (error) {
      throw FlutterBuildError(problem('cannot be run ($error)'));
    }
    final output = '${check.stdout}\n${check.stderr}';
    final version = _dartVersion.firstMatch(output)?.group(1);
    if (check.exitCode != 0 || version == null) {
      throw FlutterBuildError(
        problem('does not answer `--version` like gen_snapshot'),
      );
    }
    final expected = release.dartSdkVersion;
    if (expected != null && version != expected) {
      throw FlutterBuildError(
        problem(
          'is Dart $version, but Flutter ${release.version} uses Dart '
          '$expected',
        ),
      );
    }
    log.logTrace('Using pinned iOS gen_snapshot $path (Dart $version)');
    return path;
  }

  static final _dartVersion = RegExp(r'Dart SDK version: (\S+)');

  Future<String> _download(
    FlutterSdkRelease release,
    IosGenSnapshotMode mode,
    String platform,
  ) async {
    final manifest = await log.logStep(
      'Looking up iOS gen_snapshot for Flutter ${release.version}',
      () => _manifest(release),
    );
    if (manifest == null) throw _unavailable(release, mode);
    if (manifest.engine != release.engine ||
        manifest.flutter != release.version) {
      throw _unavailable(
        release,
        mode,
        reason:
            'The published compiler for Flutter ${manifest.flutter} targets '
            'engine ${_short(manifest.engine)}, but this SDK uses engine '
            '${release.shortEngine}. Run `flutter --version` once to refresh '
            'bin/cache/flutter.version.json after switching Flutter versions; '
            'otherwise the SDK is modified or locally built.',
      );
    }
    final name = IosGenSnapshotManifest.assetName(mode, platform);
    final asset = manifest.assets[name];
    if (asset == null) {
      throw _unavailable(
        release,
        mode,
        reason:
            'The Flutter ${release.version} release has no $name for this '
            'host.',
      );
    }
    final staging = host.fileSystem.directory(
      host.paths.context.join(cacheRoot, 'gen-snapshot'),
    );
    await staging.create(recursive: true);
    final temporary = await staging.createTemp('.download-');
    try {
      final archive = host.paths.context.join(temporary.path, name);
      try {
        await downloader.downloadToFile(
          '$releaseBaseUrl/${Uri.encodeComponent(release.version)}/$name',
          host.fileSystem.file(archive),
          maxAttempts: 5,
          label: 'iOS gen_snapshot (${mode.name})',
        );
      } on Exception catch (error) {
        throw FlutterBuildError('Could not download $name: $error');
      }
      final extracted = host.paths.context.join(temporary.path, 'extracted');
      await log.logStep('Verifying iOS gen_snapshot', () async {
        _verify(name, 'archive', asset.sha256, await _digest(archive));
        await FlutterEngineArchiveWriter(host).extractZip(archive, extracted);
        final executable = host.paths.context.join(extracted, _executableName);
        final meta = host.paths.context.join(extracted, 'meta.json');
        if (host.fileSystem.typeSync(executable, followLinks: false) !=
                FileSystemEntityType.file ||
            host.fileSystem.typeSync(meta, followLinks: false) !=
                FileSystemEntityType.notFound) {
          throw FlutterBuildError(
            '$name must contain a regular $_executableName at its root and '
            'no meta.json.',
            isSecurityFailure: true,
          );
        }
        _verify(
          name,
          _executableName,
          asset.executableSha256,
          await _digest(executable),
        );
        host.fileSystem.makeExecutable(executable);
        await host.fileSystem
            .file(meta)
            .writeAsString(
              const JsonEncoder.withIndent('  ').convert({
                'flutter': release.version,
                'engine': release.engine,
                'dart': manifest.dart ?? release.dart,
                'mode': mode.name,
                'host': platform,
                'source': 'download',
                'executable_sha256': asset.executableSha256,
                'asset_sha256': asset.sha256,
                'checked_at': _now().toUtc().toIso8601String(),
                'last_used': _now().toUtc().toIso8601String(),
              }),
              flush: true,
            );
      });
      final executable = await _install(
        extracted,
        release,
        mode,
        platform,
        executableSha256: asset.executableSha256,
      );
      log.logDone(
        'iOS gen_snapshot ${mode.name} for Flutter ${release.version}',
        executable,
      );
      return executable;
    } finally {
      try {
        if (temporary.existsSync()) await temporary.delete(recursive: true);
      } on FileSystemException catch (error) {
        log.logTrace('Could not remove ${temporary.path}: $error');
      }
    }
  }

  /// Moves a verified [extracted] compiler into the cache.
  ///
  /// Another build may install the same compiler meanwhile; a cache entry
  /// that still verifies as this exact build ([executableSha256]) is used
  /// rather than replaced, because that build may be running it. An entry
  /// holding an older, republished build is replaced.
  Future<String> _install(
    String extracted,
    FlutterSdkRelease release,
    IosGenSnapshotMode mode,
    String platform, {
    required String executableSha256,
  }) async {
    final destination = host.fileSystem.directory(
      cacheDirectory(release.engine, mode, platform),
    );
    await destination.parent.create(recursive: true);
    for (var attempt = 0; ; attempt++) {
      final installed = await cachedExecutable(release, mode, platform);
      if (installed != null &&
          await _digest(installed) == executableSha256.toLowerCase()) {
        return installed;
      }
      try {
        if (destination.existsSync()) {
          await destination.delete(recursive: true);
        }
        await host.fileSystem.directory(extracted).rename(destination.path);
        return host.paths.context.join(destination.path, _executableName);
      } on FileSystemException catch (error) {
        if (attempt >= 2) {
          throw FlutterBuildError(
            'Could not install the iOS gen_snapshot into '
            '${destination.path}: $error',
          );
        }
        log.logTrace('Retrying gen_snapshot cache install: $error');
      }
    }
  }

  void _verify(String asset, String what, String expected, String actual) {
    if (expected == actual) return;
    throw FlutterBuildError(
      'SHA-256 mismatch for the $what of $asset; refusing to use it.\n'
      '  expected: $expected\n'
      '  actual:   $actual',
      isSecurityFailure: true,
    );
  }

  /// The release manifest, or `null` when no release exists for the version.
  Future<IosGenSnapshotManifest?> _manifest(FlutterSdkRelease release) async {
    final url = Uri.parse(
      '$releaseBaseUrl/${Uri.encodeComponent(release.version)}/manifest.json',
    );
    for (var attempt = 1; ; attempt++) {
      final client = createHttpClient();
      try {
        final response = await client.get(url).timeout(manifestTimeout);
        if (response.statusCode == HttpStatus.notFound) return null;
        if (response.statusCode >= 500 && attempt < manifestAttempts) {
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw FlutterBuildError(
            'Could not look up the iOS gen_snapshot release: HTTP '
            '${response.statusCode} for $url',
          );
        }
        return IosGenSnapshotManifest.parse(response.body);
      } on IosGenSnapshotSchemaException catch (error) {
        throw FlutterBuildError(
          'The iOS gen_snapshot release manifest at $url uses schema '
          '${error.schema}, which needs a newer xcross. Run `xcross update` '
          'and build again.',
        );
      } on FormatException catch (error) {
        throw FlutterBuildError(
          'The iOS gen_snapshot release manifest at $url is invalid: '
          '${error.message}',
        );
      } on Exception catch (error) {
        if (error is FlutterBuildError) rethrow;
        if (attempt >= manifestAttempts) {
          throw FlutterBuildError(
            'Could not look up the iOS gen_snapshot release at $url: $error',
          );
        }
        log.logTrace('Retrying $url after: $error');
      } finally {
        client.close();
      }
    }
  }

  @visibleForTesting
  static const manifestAttempts = 3;

  @visibleForTesting
  static const manifestTimeout = Duration(seconds: 30);

  FlutterBuildError _unavailable(
    FlutterSdkRelease release,
    IosGenSnapshotMode mode, {
    String? reason,
  }) {
    final executable = _executableName;
    final buffer = StringBuffer(
      'No prebuilt iOS AOT compiler (gen_snapshot) is available for '
      'Flutter ${release.version} (engine ${release.shortEngine}).\n',
    );
    if (reason != null) buffer.writeln(reason);
    buffer
      ..writeln(
        'Flutter publishes this compiler for macOS only; xcross downloads '
        'Linux and Windows builds from $repositoryUrl/releases.',
      )
      ..writeln(
        'Switch to a Flutter version released there, or pin a compiler built '
        'for engine ${release.engine} in xcross config '
        '(`xcross config show` prints its path):',
      )
      ..writeln('  ios_gen_snapshot:')
      ..writeln('    "${release.version}":')
      ..write('      ${mode.name}: /absolute/path/to/$executable');
    return FlutterBuildError(buffer.toString());
  }

  Future<String> _digest(String path) async =>
      (await sha256.bind(host.fileSystem.file(path).openRead()).first)
          .toString();

  /// How long a cached compiler is trusted before its manifest is consulted
  /// again for a republished build.
  static const revalidateAfter = Duration(hours: 24);

  /// Ceiling on the revalidation lookup, so a slow network never holds up a
  /// build that already has a working compiler.
  static const revalidateTimeout = Duration(seconds: 5);

  /// Checks a cached download against its release once [revalidateAfter]
  /// has passed, returning [cached] when it is still current and null when
  /// the release now publishes a different build.
  ///
  /// Best effort by design: offline, rate limited, or a release that has
  /// disappeared all keep using the verified compiler already on disk.
  Future<String?> _revalidate(
    String cached,
    FlutterSdkRelease release,
    IosGenSnapshotMode mode,
    String platform,
  ) async {
    final meta = host.fileSystem.file(
      host.paths.context.join(
        cacheDirectory(release.engine, mode, platform),
        'meta.json',
      ),
    );
    final Map<String, Object?> document;
    try {
      final Object? decoded = jsonDecode(meta.readAsStringSync());
      if (decoded is! Map<String, Object?>) return cached;
      document = decoded;
    } on Object {
      return cached;
    }
    if (document['source'] != 'download') return cached;
    final checkedAt = DateTime.tryParse('${document['checked_at']}');
    if (checkedAt != null && _now().difference(checkedAt) < revalidateAfter) {
      return cached;
    }
    IosGenSnapshotManifest? manifest;
    try {
      manifest = await _fetchManifestOnce(release);
    } on Object catch (error) {
      log.logTrace('Skipping gen_snapshot revalidation: $error');
      return cached;
    }
    final asset =
        manifest?.assets[IosGenSnapshotManifest.assetName(mode, platform)];
    if (manifest == null ||
        asset == null ||
        manifest.engine != release.engine) {
      _writeMeta(meta, {...document, 'checked_at': _stamp()});
      return cached;
    }
    final recorded = document['asset_sha256'];
    final republished = recorded is String
        ? recorded != asset.sha256
        : document['executable_sha256'] != asset.executableSha256;
    if (republished) {
      log.logWarn(
        'The iOS ${mode.name} gen_snapshot for Flutter ${release.version} '
        'was republished; downloading the new build.',
      );
      return null;
    }
    _writeMeta(meta, {
      ...document,
      'asset_sha256': asset.sha256,
      'checked_at': _stamp(),
    });
    return cached;
  }

  /// One manifest request without the retries a first download uses.
  ///
  /// The timeout bounds the request itself rather than its caller, so the
  /// client is closed when it fires: an abandoned connection to a server
  /// that never answers would otherwise keep xcross from exiting.
  Future<IosGenSnapshotManifest?> _fetchManifestOnce(
    FlutterSdkRelease release,
  ) async {
    final url = Uri.parse(
      '$releaseBaseUrl/${Uri.encodeComponent(release.version)}/manifest.json',
    );
    final client = createHttpClient();
    try {
      final response = await client.get(url).timeout(revalidateTimeout);
      if (response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      return IosGenSnapshotManifest.parse(response.body);
    } finally {
      client.close();
    }
  }

  /// Records that a cache entry was used, for `xcross cache prune`.
  void _touch(String directory) {
    final meta = host.fileSystem.file(
      host.paths.context.join(directory, 'meta.json'),
    );
    try {
      final Object? decoded = jsonDecode(meta.readAsStringSync());
      if (decoded is! Map<String, Object?>) return;
      _writeMeta(meta, {...decoded, 'last_used': _stamp()});
    } on Object {
      // A read-only cache only costs prune accuracy.
    }
  }

  /// Written through a sibling and a rename, so a concurrent build never
  /// reads a half-written file and mistakes a good entry for a broken one.
  void _writeMeta(File meta, Map<String, Object?> document) {
    final staged = host.fileSystem.file('${meta.path}.$pid.tmp');
    try {
      staged.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(document),
        flush: true,
      );
      staged.renameSync(meta.path);
    } on FileSystemException catch (error) {
      log.logTrace('Could not update ${meta.path}: $error');
      try {
        if (staged.existsSync()) staged.deleteSync();
      } on FileSystemException {
        // Left for the next prune.
      }
    }
  }

  String _stamp() => _now().toUtc().toIso8601String();

  static String _short(String engine) =>
      engine.length > 8 ? engine.substring(0, 8) : engine;
}

/// Whether an iOS AOT compiler is available, and from where.
@internal
@immutable
final class IosGenSnapshotAvailability {
  const IosGenSnapshotAvailability({
    this.source,
    this.path,
    this.release,
    this.detail,
    this.unknown = false,
  });

  /// Where a build would take the compiler from, or null when none exists.
  final IosGenSnapshotSource? source;

  /// The compiler on disk, for shipped, cached, and pinned compilers.
  final String? path;
  final FlutterSdkRelease? release;

  /// Why no compiler is available, or why that could not be determined.
  final String? detail;

  /// True when the published release could not be checked (offline).
  final bool unknown;

  bool get available => source != null;
}
