import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
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
  flutterSdk('flutter-sdk'),

  /// A verified download reused from the xcross cache.
  cache('cache'),

  /// A compiler path the user pinned in xcross config.
  pinned('pinned'),

  /// Downloaded from xcross_gen_snapshot by this resolution.
  download('download');

  const IosGenSnapshotSource(this.label);

  final String label;
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
  }) {
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

  T get host => runner.host;
  Log get log => runner.log;

  /// Resolves the [mode] compiler for the Flutter SDK at [flutterRoot].
  Future<IosGenSnapshot> resolve({
    required String flutterRoot,
    required IosGenSnapshotMode mode,
  }) async {
    final release = FlutterSdkReleaseReader(host).read(flutterRoot);
    IosGenSnapshot result(String path, IosGenSnapshotSource source) =>
        IosGenSnapshot(
          executable: path,
          mode: mode,
          release: release,
          source: source,
        );

    final shipped = hostPolicy.flutterCompiler(flutterRoot, mode);
    if (shipped != null) {
      return result(shipped, IosGenSnapshotSource.flutterSdk);
    }
    final platform = hostPolicy.prebuiltPlatform;
    final cached = await cachedExecutable(release, mode, platform);
    if (cached != null) return result(cached, IosGenSnapshotSource.cache);
    final pinned = await _pinned(release, mode);
    if (pinned != null) return result(pinned, IosGenSnapshotSource.pinned);
    final downloaded = await _download(release, mode, platform);
    return result(downloaded, IosGenSnapshotSource.download);
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
    final pin = pins[release.version] ?? pins[release.engine];
    final path = pin?.forMode(mode.name);
    if (path == null) return null;
    final key = pins.containsKey(release.version)
        ? release.version
        : release.engine;
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
    if (manifest.engine != release.engine) {
      throw _unavailable(
        release,
        mode,
        reason:
            'The published compiler for Flutter ${release.version} targets '
            'engine ${_short(manifest.engine)}, but this SDK uses engine '
            '${release.shortEngine} (a modified or locally built Flutter SDK).',
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
      await downloader.downloadToFile(
        '$releaseBaseUrl/${Uri.encodeComponent(release.version)}/$name',
        host.fileSystem.file(archive),
        maxAttempts: 5,
        label: 'iOS gen_snapshot (${mode.name})',
      );
      final extracted = host.paths.context.join(temporary.path, 'extracted');
      await log.logStep('Verifying iOS gen_snapshot', () async {
        _verify(name, 'archive', asset.sha256, await _digest(archive));
        await FlutterEngineArchiveWriter(host).extractZip(archive, extracted);
        final executable = host.paths.context.join(extracted, _executableName);
        if (!host.fileSystem.file(executable).existsSync()) {
          throw FlutterBuildError(
            '$name does not contain $_executableName at its root.',
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
            .file(host.paths.context.join(extracted, 'meta.json'))
            .writeAsString(
              const JsonEncoder.withIndent('  ').convert({
                'flutter': release.version,
                'engine': release.engine,
                'dart': manifest.dart ?? release.dart,
                'mode': mode.name,
                'host': platform,
                'source': 'download',
                'executable_sha256': asset.executableSha256,
              }),
              flush: true,
            );
      });
      final destination = cacheDirectory(release.engine, mode, platform);
      final existing = host.fileSystem.directory(destination);
      if (existing.existsSync()) await existing.delete(recursive: true);
      await existing.parent.create(recursive: true);
      await host.fileSystem.directory(extracted).rename(destination);
      final executable = host.paths.context.join(destination, _executableName);
      log.logDone(
        'iOS gen_snapshot ${mode.name} for Flutter ${release.version}',
        executable,
      );
      return executable;
    } finally {
      if (temporary.existsSync()) await temporary.delete(recursive: true);
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
    final client = createHttpClient();
    try {
      final response = await client.get(url);
      if (response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FlutterBuildError(
          'Could not look up the iOS gen_snapshot release: HTTP '
          '${response.statusCode} for $url',
        );
      }
      return IosGenSnapshotManifest.parse(response.body);
    } on FormatException catch (error) {
      throw FlutterBuildError(
        'The iOS gen_snapshot release manifest at $url is invalid: '
        '${error.message}',
      );
    } on http.ClientException catch (error) {
      throw FlutterBuildError(
        'Could not look up the iOS gen_snapshot release at $url: '
        '${error.message}',
      );
    } on SocketException catch (error) {
      throw FlutterBuildError(
        'Could not look up the iOS gen_snapshot release at $url: '
        '${error.message}',
      );
    } finally {
      client.close();
    }
  }

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

  static String _short(String engine) =>
      engine.length > 8 ? engine.substring(0, 8) : engine;
}
