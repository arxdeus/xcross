@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_paths.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/composition/flutter/ios_gen_snapshot.dart';
import 'package:xcross/src/host/linux/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/host/macos/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/host/shared/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/host/windows/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/shared/config/config.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/flutter_sdk_release.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_manifest.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_resolver.dart';

import '../../log_fixture.dart';

const _engine = '5f77625673248ee5846fbcaf5d3e1a3878386fd7';
const _dart = 'da6595cd6bb5d4c0a185d759a025e879ff06e631';
const _binary = [0x7f, 0x45, 0x4c, 0x46, 1, 2, 3, 4];

void main() {
  late Directory temporary;
  late String flutterRoot;
  late String engineDirectory;
  late String cacheRoot;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('xcross-gen-snapshot-');
    flutterRoot = p.join(temporary.path, 'flutter');
    engineDirectory = p.join(temporary.path, 'engine', 'ios-release');
    cacheRoot = p.join(temporary.path, 'cache');
    _writeFlutterSdk(flutterRoot);
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  group('FlutterSdkReleaseReader', () {
    test('reads version, engine, and Dart identity from the SDK', () {
      final release = FlutterSdkReleaseReader(LinuxHost()).read(flutterRoot);
      expect(release.version, '3.47.0');
      expect(release.engine, _engine);
      expect(release.dart, _dart);
      expect(release.dartSdkVersion, '3.13.0');
      expect(release.shortEngine, '5f776256');
    });

    test('falls back to the version file without flutter.version.json', () {
      File(
        p.join(flutterRoot, 'bin', 'cache', 'flutter.version.json'),
      ).deleteSync();
      File(p.join(flutterRoot, 'version')).writeAsStringSync('3.47.6\n');
      expect(
        FlutterSdkReleaseReader(LinuxHost()).read(flutterRoot).version,
        '3.47.6',
      );
    });

    test('reports a missing engine revision', () {
      File(
        p.join(flutterRoot, 'bin', 'internal', 'engine.version'),
      ).deleteSync();
      expect(
        () => FlutterSdkReleaseReader(LinuxHost()).read(flutterRoot),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('engine revision'),
          ),
        ),
      );
    });
  });

  group('IosGenSnapshotManifest', () {
    test('parses assets and lowercases digests', () {
      final manifest = IosGenSnapshotManifest.parse(
        jsonEncode(
          _manifest({
            'gen_snapshot-release-linux-x64.zip': _assetJson(
              'A' * 64,
              'b' * 64,
              12,
            ),
          }),
        ),
      );
      expect(manifest.flutter, '3.47.0');
      expect(manifest.engine, _engine);
      expect(manifest.dart, _dart);
      final asset = manifest.assets['gen_snapshot-release-linux-x64.zip']!;
      expect(asset.sha256, 'a' * 64);
      expect(asset.executableSha256, 'b' * 64);
      expect(asset.size, 12);
    });

    for (final (label, document) in <(String, Object?)>[
      ('non-JSON', null),
      ('a list', <Object>[]),
      ('another schema', {..._manifest(const {}), 'schema': 2}),
      ('a missing engine', {..._manifest(const {})}..remove('engine')),
      ('assets as a list', {..._manifest(const {}), 'assets': <Object>[]}),
      ('a short digest', _manifest({'x.zip': _assetJson('ab', 'b' * 64, 1)})),
      (
        'a negative size',
        _manifest({'x.zip': _assetJson('a' * 64, 'b' * 64, -1)}),
      ),
    ]) {
      test('rejects $label', () {
        expect(
          () => IosGenSnapshotManifest.parse(
            document == null ? '<html>' : jsonEncode(document),
          ),
          throwsFormatException,
        );
      });
    }

    test('names assets by mode and host platform', () {
      expect(
        IosGenSnapshotManifest.assetName(
          IosGenSnapshotMode.profile,
          'windows-arm64',
        ),
        'gen_snapshot-profile-windows-arm64.zip',
      );
    });
  });

  group('host selection', () {
    for (final (host, expected) in <(IosGenSnapshotHost, String)>[
      (LinuxIosGenSnapshotHost(LinuxHost(architecture: 'x64')), 'linux-x64'),
      (
        LinuxIosGenSnapshotHost(LinuxHost(architecture: 'arm64')),
        'linux-arm64',
      ),
      (
        WindowsIosGenSnapshotHost(
          WindowsHost(architecture: 'x64', paths: PosixPaths()),
        ),
        'windows-x64',
      ),
      (
        WindowsIosGenSnapshotHost(
          WindowsHost(architecture: 'arm64', paths: PosixPaths()),
        ),
        'windows-arm64',
      ),
    ]) {
      test('${host.host.name} ${host.host.architecture} uses $expected', () {
        expect(host.prebuiltPlatform, expected);
        expect(
          host.flutterCompiler('/engine', IosGenSnapshotMode.release),
          isNull,
        );
      });
    }

    test('rejects host architectures without published compilers', () {
      expect(
        () => LinuxIosGenSnapshotHost(
          LinuxHost(architecture: 'riscv64'),
        ).prebuiltPlatform,
        throwsA(isA<FlutterBuildError>()),
      );
    });

    test('composition picks the host policy', () {
      expect(
        composeIosGenSnapshotHost(LinuxHost(architecture: 'x64')),
        isA<LinuxIosGenSnapshotHost>(),
      );
      expect(
        composeIosGenSnapshotHost(WindowsHost(architecture: 'x64')),
        isA<WindowsIosGenSnapshotHost>(),
      );
      expect(
        composeIosGenSnapshotHost(MacOSHost(architecture: 'arm64')),
        isA<MacOSIosGenSnapshotHost>(),
      );
    });

    test('macOS uses the compiler beside the build engine', () async {
      final host = MacOSHost(architecture: 'arm64');
      for (final mode in IosGenSnapshotMode.values) {
        final engine = p.join(temporary.path, 'engine', mode.engineArtifact);
        final compiler = p.join(engine, 'gen_snapshot_arm64');
        File(compiler)
          ..createSync(recursive: true)
          ..writeAsBytesSync(_binary);
        final resolver = _resolver(
          MacOSIosGenSnapshotHost(host),
          host,
          cacheRoot: cacheRoot,
          httpClient: _rejectingClient,
        );
        final resolved = await resolver.resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engine,
          mode: mode,
        );
        expect(resolved.executable, compiler);
        expect(resolved.source, IosGenSnapshotSource.flutterSdk);
      }
    });

    test('macOS reports a missing Flutter compiler', () {
      final host = MacOSHost(architecture: 'arm64');
      expect(
        () => MacOSIosGenSnapshotHost(
          host,
        ).flutterCompiler(engineDirectory, IosGenSnapshotMode.release),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains(p.join(engineDirectory, 'gen_snapshot_arm64')),
              contains('xcross flutter precache --mode release'),
            ),
          ),
        ),
      );
    });
  });

  group('IosGenSnapshotResolver', () {
    late LinuxHost host;
    late ReleaseServer server;

    setUp(() async {
      host = LinuxHost(architecture: 'x64');
      server = await ReleaseServer.start();
    });
    tearDown(() => server.close());

    IosGenSnapshotResolver<LinuxHost> resolver({
      Map<String, XcrossIosGenSnapshotPin> pins = const {},
      DateTime Function()? now,
    }) => _resolver(
      LinuxIosGenSnapshotHost(host),
      host,
      cacheRoot: cacheRoot,
      httpClient: server.manifestClient,
      releaseBaseUrl: server.baseUrl,
      pins: pins,
      now: now,
    );

    test('downloads, verifies, and caches the host compiler', () async {
      server.publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64');
      final resolved = await resolver().resolve(
        flutterRoot: flutterRoot,
        engineDirectory: engineDirectory,
        mode: IosGenSnapshotMode.release,
      );
      final directory = p.join(
        cacheRoot,
        'gen-snapshot',
        _engine,
        'release',
        'linux-x64',
      );
      expect(resolved.source, IosGenSnapshotSource.download);
      expect(resolved.executable, p.join(directory, 'gen_snapshot'));
      expect(File(resolved.executable).readAsBytesSync(), _binary);
      expect(
        File(resolved.executable).statSync().modeString(),
        startsWith('rwx'),
      );
      final meta =
          jsonDecode(File(p.join(directory, 'meta.json')).readAsStringSync())
              as Map<String, Object?>;
      expect(meta, {
        'flutter': '3.47.0',
        'engine': _engine,
        'dart': _dart,
        'mode': 'release',
        'host': 'linux-x64',
        'source': 'download',
        'executable_sha256': _sha(_binary),
        'asset_sha256': isA<String>().having((s) => s.length, 'length', 64),
        'checked_at': isA<String>(),
        'last_used': isA<String>(),
      });
      expect(server.requests, [
        '/3.47.0/manifest.json',
        '/3.47.0/gen_snapshot-release-linux-x64.zip',
      ]);
      expect(
        Directory(
          p.join(cacheRoot, 'gen-snapshot'),
        ).listSync().map((entity) => p.basename(entity.path)),
        [_engine],
      );
    });

    test('reuses a verified cache entry without network access', () async {
      server.publish('3.47.0', IosGenSnapshotMode.profile, 'linux-x64');
      await resolver().resolve(
        flutterRoot: flutterRoot,
        engineDirectory: engineDirectory,
        mode: IosGenSnapshotMode.profile,
      );
      server.requests.clear();
      final resolved = await resolver().resolve(
        flutterRoot: flutterRoot,
        engineDirectory: engineDirectory,
        mode: IosGenSnapshotMode.profile,
      );
      expect(resolved.source, IosGenSnapshotSource.cache);
      expect(server.requests, isEmpty);
    });

    test('downloads again when the cached executable was altered', () async {
      server.publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64');
      final first = await resolver().resolve(
        flutterRoot: flutterRoot,
        engineDirectory: engineDirectory,
        mode: IosGenSnapshotMode.release,
      );
      File(first.executable).writeAsBytesSync([0, 0, 0]);
      server.requests.clear();
      final second = await resolver().resolve(
        flutterRoot: flutterRoot,
        engineDirectory: engineDirectory,
        mode: IosGenSnapshotMode.release,
      );
      expect(second.source, IosGenSnapshotSource.download);
      expect(File(second.executable).readAsBytesSync(), _binary);
      expect(server.requests, hasLength(2));
    });

    test('ignores cache metadata for another engine or host', () async {
      final directory = p.join(
        cacheRoot,
        'gen-snapshot',
        _engine,
        'release',
        'linux-x64',
      );
      File(p.join(directory, 'gen_snapshot'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(_binary);
      final meta = File(p.join(directory, 'meta.json'));
      final release = FlutterSdkReleaseReader(host).read(flutterRoot);
      final subject = resolver();
      for (final document in [
        {
          'engine': 'other',
          'mode': 'release',
          'host': 'linux-x64',
          'executable_sha256': _sha(_binary),
        },
        {
          'engine': _engine,
          'mode': 'release',
          'host': 'linux-arm64',
          'executable_sha256': _sha(_binary),
        },
      ]) {
        meta.writeAsStringSync(jsonEncode(document));
        expect(
          await subject.cachedExecutable(
            release,
            IosGenSnapshotMode.release,
            'linux-x64',
          ),
          isNull,
        );
      }
      meta.writeAsStringSync('not json');
      expect(
        await subject.cachedExecutable(
          release,
          IosGenSnapshotMode.release,
          'linux-x64',
        ),
        isNull,
      );
    });

    test('fails with guidance when no release exists', () async {
      await expectLater(
        resolver().resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Flutter 3.47.0 (engine 5f776256)'),
              contains('ios_gen_snapshot:'),
              contains('release: /absolute/path/to/gen_snapshot'),
              contains(IosGenSnapshotResolver.repositoryUrl),
            ),
          ),
        ),
      );
      expect(server.requests, ['/3.47.0/manifest.json']);
    });

    test('treats a release for another engine as unavailable', () async {
      server.publish(
        '3.47.0',
        IosGenSnapshotMode.release,
        'linux-x64',
        engine: 'a' * 40,
      );
      await expectLater(
        resolver().resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            allOf(contains('engine aaaaaaaa'), contains('modified')),
          ),
        ),
      );
      expect(server.requests, ['/3.47.0/manifest.json']);
    });

    test('reports a release without an asset for this host', () async {
      server.publish('3.47.0', IosGenSnapshotMode.release, 'windows-x64');
      await expectLater(
        resolver().resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('gen_snapshot-release-linux-x64.zip'),
          ),
        ),
      );
    });

    for (final (label, tamper) in <(String, ReleaseTamper)>[
      ('archive', ReleaseTamper.archive),
      ('executable', ReleaseTamper.executable),
    ]) {
      test('rejects a download whose $label digest differs', () async {
        server.publish(
          '3.47.0',
          IosGenSnapshotMode.release,
          'linux-x64',
          tamper: tamper,
        );
        await expectLater(
          resolver().resolve(
            flutterRoot: flutterRoot,
            engineDirectory: engineDirectory,
            mode: IosGenSnapshotMode.release,
          ),
          throwsA(
            isA<FlutterBuildError>()
                .having((error) => error.isSecurityFailure, 'security', true)
                .having(
                  (error) => error.message,
                  'message',
                  contains('SHA-256 mismatch'),
                ),
          ),
        );
        final engineCache = Directory(
          p.join(cacheRoot, 'gen-snapshot', _engine),
        );
        expect(engineCache.existsSync(), isFalse);
        expect(
          Directory(p.join(cacheRoot, 'gen-snapshot')).listSync(),
          isEmpty,
        );
      });
    }

    test('reports a malformed manifest and HTTP failures', () async {
      server.manifestOverride = (200, '<html>rate limited</html>');
      await expectLater(
        resolver().resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('manifest'),
          ),
        ),
      );
      server.manifestOverride = (503, 'down');
      await expectLater(
        resolver().resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('HTTP 503'),
          ),
        ),
      );
    });

    test('retries transient manifest failures', () async {
      server
        ..publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64')
        ..manifestFailures.addAll([
          503,
          const SocketException('connection reset'),
        ]);
      final resolved = await resolver().resolve(
        flutterRoot: flutterRoot,
        engineDirectory: engineDirectory,
        mode: IosGenSnapshotMode.release,
      );
      expect(resolved.source, IosGenSnapshotSource.download);
      expect(
        server.requests.where((path) => path.endsWith('manifest.json')),
        hasLength(3),
      );
    });

    test('refuses a manifest published for another Flutter version', () async {
      server.publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64');
      server.manifestOverride = (
        200,
        jsonEncode({
          ...jsonDecode(server.manifestFor('3.47.0')) as Map<String, Object?>,
          'flutter': '3.47.1',
        }),
      );
      await expectLater(
        resolver().resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('flutter --version'),
          ),
        ),
      );
    });

    group('revalidation', () {
      const day = IosGenSnapshotResolver.revalidateAfter;
      final start = DateTime.utc(2026, 10, 9, 12);

      Future<void> seed() async {
        server.publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64');
        await resolver(now: () => start).resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        server.requests.clear();
      }

      test('trusts a recently checked entry without network', () async {
        await seed();
        final resolved =
            await resolver(
              now: () => start.add(const Duration(hours: 1)),
            ).resolve(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.release,
            );
        expect(resolved.source, IosGenSnapshotSource.cache);
        expect(server.requests, isEmpty);
      });

      test('keeps an unchanged entry after the check interval', () async {
        await seed();
        final later = start.add(day * 2);
        final resolved = await resolver(now: () => later).resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        expect(resolved.source, IosGenSnapshotSource.cache);
        expect(server.requests, ['/3.47.0/manifest.json']);
        final meta = _readMeta(cacheRoot);
        expect(meta['checked_at'], later.toIso8601String());
        expect(meta['last_used'], later.toIso8601String());
      });

      test('downloads again when the release was republished', () async {
        await seed();
        server.republish(
          '3.47.0',
          IosGenSnapshotMode.release,
          'linux-x64',
          binary: [..._binary, 9],
        );
        final resolved = await resolver(now: () => start.add(day * 2)).resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        expect(resolved.source, IosGenSnapshotSource.download);
        expect(File(resolved.executable).readAsBytesSync(), [..._binary, 9]);
      });

      test('keeps working offline', () async {
        await seed();
        server.manifestFailures.add(const SocketException('offline'));
        final resolved = await resolver(now: () => start.add(day * 2)).resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        expect(resolved.source, IosGenSnapshotSource.cache);
      });

      test('closes the connection when the manifest server never answers, '
          'so xcross can exit', () async {
        await seed();
        final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(silent.close);
        final closed = Completer<void>();
        silent.listen(
          (socket) => socket.listen(
            (_) {},
            onDone: () {
              socket.destroy();
              if (!closed.isCompleted) closed.complete();
            },
          ),
        );
        final resolved =
            await _resolver(
              LinuxIosGenSnapshotHost(host),
              host,
              cacheRoot: cacheRoot,
              httpClient: http.Client(),
              releaseBaseUrl: 'http://127.0.0.1:${silent.port}',
              now: () => start.add(day * 2),
            ).resolve(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.release,
            );
        expect(resolved.source, IosGenSnapshotSource.cache);
        await closed.future.timeout(const Duration(seconds: 5));
      });

      test('keeps the entry when the release disappeared', () async {
        await seed();
        server.manifestOverride = (404, 'Not Found');
        final resolved = await resolver(now: () => start.add(day * 2)).resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        expect(resolved.source, IosGenSnapshotSource.cache);
      });

      test('revalidates entries cached before checks were recorded', () async {
        await seed();
        final meta = _readMeta(cacheRoot)
          ..remove('checked_at')
          ..remove('asset_sha256');
        File(_metaPath(cacheRoot)).writeAsStringSync(jsonEncode(meta));
        final resolved =
            await resolver(
              now: () => start.add(const Duration(minutes: 1)),
            ).resolve(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.release,
            );
        expect(resolved.source, IosGenSnapshotSource.cache);
        expect(server.requests, ['/3.47.0/manifest.json']);
        expect(_readMeta(cacheRoot)['asset_sha256'], isA<String>());
      });
    });

    test('asks for a newer xcross when the manifest schema is newer', () async {
      server.manifestOverride = (
        200,
        jsonEncode({..._manifest(const {}), 'schema': 2}),
      );
      await expectLater(
        resolver().resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            allOf(contains('schema 2'), contains('xcross update')),
          ),
        ),
      );
    });

    group('availability', () {
      test('reports a published compiler without downloading it', () async {
        server.publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64');
        final found = await resolver().availability(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        expect(found.source, IosGenSnapshotSource.download);
        expect(server.requests, ['/3.47.0/manifest.json']);
        expect(Directory(cacheRoot).existsSync(), isFalse);
      });

      test('reports a cached compiler', () async {
        server.publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64');
        await resolver().resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        final found = await resolver().availability(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        expect(found.source, IosGenSnapshotSource.cache);
        expect(found.path, endsWith('gen_snapshot'));
      });

      test('reports an unpublished version as unavailable', () async {
        final found = await resolver().availability(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.profile,
        );
        expect(found.available, isFalse);
        expect(found.unknown, isFalse);
        expect(found.detail, contains('Flutter 3.47.0'));
      });

      test('reports a failed lookup as unknown rather than throwing', () async {
        server.manifestFailures.add(const SocketException('offline'));
        final found = await resolver().availability(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        expect(found.available, isFalse);
        expect(found.unknown, isTrue);
      });

      test('macOS reports the compiler beside the build engine', () async {
        final host = MacOSHost(architecture: 'arm64');
        final compiler = p.join(engineDirectory, 'gen_snapshot_arm64');
        File(compiler)
          ..createSync(recursive: true)
          ..writeAsBytesSync(_binary);
        final sdkCompiler = p.join(
          flutterRoot,
          'bin',
          'cache',
          'artifacts',
          'engine',
          'ios-release',
          'gen_snapshot_arm64',
        );
        File(sdkCompiler)
          ..createSync(recursive: true)
          ..writeAsBytesSync(_binary);
        final found =
            await _resolver(
              MacOSIosGenSnapshotHost(host),
              host,
              cacheRoot: cacheRoot,
              httpClient: _rejectingClient,
            ).availability(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.release,
            );
        expect(found.source, IosGenSnapshotSource.flutterSdk);
        expect(found.path, compiler);
      });

      test(
        'macOS reports a missing engine compiler without throwing',
        () async {
          final host = MacOSHost(architecture: 'arm64');
          final found =
              await _resolver(
                MacOSIosGenSnapshotHost(host),
                host,
                cacheRoot: cacheRoot,
                httpClient: _rejectingClient,
              ).availability(
                flutterRoot: flutterRoot,
                engineDirectory: engineDirectory,
                mode: IosGenSnapshotMode.profile,
              );
          expect(found.available, isFalse);
          expect(
            found.detail,
            allOf(
              contains(p.join(engineDirectory, 'gen_snapshot_arm64')),
              contains('xcross flutter precache --mode profile'),
            ),
          );
        },
      );
    });

    test('concurrent resolves share one installed compiler', () async {
      server.publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64');
      final results = await Future.wait([
        for (var i = 0; i < 4; i++)
          resolver().resolve(
            flutterRoot: flutterRoot,
            engineDirectory: engineDirectory,
            mode: IosGenSnapshotMode.release,
          ),
      ]);
      final executable = results.first.executable;
      expect(results.map((result) => result.executable).toSet(), {executable});
      expect(File(executable).readAsBytesSync(), _binary);
      expect(
        Directory(p.join(cacheRoot, 'gen-snapshot'))
            .listSync()
            .map((entity) => p.basename(entity.path))
            .where((name) => name.startsWith('.download-')),
        isEmpty,
      );
    });

    group('pins', () {
      String fakeCompiler(String dartVersion, {int exitCode = 0}) {
        final script = File(p.join(temporary.path, 'pinned', 'gen_snapshot'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '#!/bin/sh\n'
            'echo "Dart SDK version: $dartVersion (stable) on '
            '\\"linux_x64\\"" >&2\n'
            'exit $exitCode\n',
          );
        host.fileSystem.makeExecutable(script.path);
        return script.path;
      }

      test('uses a pinned compiler keyed by Flutter version', () async {
        final path = fakeCompiler('3.13.0');
        final resolved =
            await resolver(
              pins: {'3.47.0': XcrossIosGenSnapshotPin(release: path)},
            ).resolve(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.release,
            );
        expect(resolved.executable, path);
        expect(resolved.source, IosGenSnapshotSource.pinned);
        expect(server.requests, isEmpty);
      });

      test('uses a pinned compiler keyed by engine revision', () async {
        final path = fakeCompiler('3.13.0');
        final resolved =
            await resolver(
              pins: {_engine: XcrossIosGenSnapshotPin(profile: path)},
            ).resolve(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.profile,
            );
        expect(resolved.source, IosGenSnapshotSource.pinned);
      });

      test('an engine pin serves the mode a version pin lacks', () async {
        final path = fakeCompiler('3.13.0');
        final resolved =
            await resolver(
              pins: {
                '3.47.0': XcrossIosGenSnapshotPin(release: path),
                _engine: XcrossIosGenSnapshotPin(profile: path),
              },
            ).resolve(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.profile,
            );
        expect(resolved.source, IosGenSnapshotSource.pinned);
        expect(server.requests, isEmpty);
      });

      test('a pin for the other mode does not apply', () async {
        server.publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64');
        final resolved =
            await resolver(
              pins: {
                '3.47.0': XcrossIosGenSnapshotPin(
                  profile: fakeCompiler('3.13.0'),
                ),
              },
            ).resolve(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.release,
            );
        expect(resolved.source, IosGenSnapshotSource.download);
      });

      test('a verified cache wins over a pin', () async {
        server.publish('3.47.0', IosGenSnapshotMode.release, 'linux-x64');
        await resolver().resolve(
          flutterRoot: flutterRoot,
          engineDirectory: engineDirectory,
          mode: IosGenSnapshotMode.release,
        );
        final resolved =
            await resolver(
              pins: {
                '3.47.0': XcrossIosGenSnapshotPin(
                  release: fakeCompiler('3.13.0'),
                ),
              },
            ).resolve(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.release,
            );
        expect(resolved.source, IosGenSnapshotSource.cache);
      });

      for (final (label, pin, message) in <(String, String Function(), String)>[
        (
          'a missing file',
          () => p.join(temporary.path, 'missing'),
          'does not exist',
        ),
        (
          'a failing --version',
          () => fakeCompiler('3.13.0', exitCode: 255),
          '--version',
        ),
        (
          'another Dart version',
          () => fakeCompiler('3.12.0'),
          'is Dart 3.12.0, but Flutter 3.47.0 uses Dart 3.13.0',
        ),
      ]) {
        test('rejects a pin to $label', () async {
          await expectLater(
            resolver(
              pins: {'3.47.0': XcrossIosGenSnapshotPin(release: pin())},
            ).resolve(
              flutterRoot: flutterRoot,
              engineDirectory: engineDirectory,
              mode: IosGenSnapshotMode.release,
            ),
            throwsA(
              isA<FlutterBuildError>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('ios_gen_snapshot.3.47.0.release'),
                  contains(message),
                ),
              ),
            ),
          );
          expect(server.requests, isEmpty);
        });
      }
    }, testOn: 'posix');
  });
}

IosGenSnapshotResolver<T> _resolver<T extends PlatformHostInterface>(
  IosGenSnapshotHost policy,
  T host, {
  required String cacheRoot,
  required http.Client httpClient,
  String releaseBaseUrl = 'https://invalid.test/releases/download',
  Map<String, XcrossIosGenSnapshotPin> pins = const {},
  DateTime Function()? now,
}) {
  final log = testLog();
  return IosGenSnapshotResolver(
    hostPolicy: policy,
    runner: ProcessRunner(
      host,
      log: log,
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: testByteSink(),
      stderrSink: testByteSink(),
    ),
    downloader: Downloader(createClient: HttpClient.new, log: log),
    createHttpClient: () => httpClient,
    cacheRoot: cacheRoot,
    releaseBaseUrl: releaseBaseUrl,
    pins: pins,
    now: now,
  );
}

final _rejectingClient = MockClient(
  (request) => throw StateError('unexpected request ${request.url}'),
);

void _writeFlutterSdk(String root) {
  void write(List<String> path, String contents) =>
      File(p.joinAll([root, ...path]))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
  write(['bin', 'internal', 'engine.version'], '$_engine\n');
  write(['bin', 'cache', 'dart-sdk', 'revision'], _dart);
  write(['bin', 'cache', 'dart-sdk', 'version'], '3.13.0\n');
  write(
    ['bin', 'cache', 'flutter.version.json'],
    jsonEncode({
      'frameworkVersion': '3.47.0',
      'engineRevision': _engine,
      'dartSdkVersion': '3.13.0',
    }),
  );
}

Map<String, Object?> _manifest(Map<String, Object?> assets, {String? engine}) =>
    {
      'schema': 1,
      'flutter': '3.47.0',
      'engine': engine ?? _engine,
      'dart': _dart,
      'patch_sha256': 'c' * 64,
      'assets': assets,
    };

Map<String, Object?> _assetJson(String zip, String executable, int size) => {
  'sha256': zip,
  'executable_sha256': executable,
  'size': size,
};

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

String _metaPath(String cacheRoot) => p.join(
  cacheRoot,
  'gen-snapshot',
  _engine,
  'release',
  'linux-x64',
  'meta.json',
);

Map<String, Object?> _readMeta(String cacheRoot) =>
    jsonDecode(File(_metaPath(cacheRoot)).readAsStringSync())
        as Map<String, Object?>;

@internal
enum ReleaseTamper { none, archive, executable }

/// Serves release assets over loopback for the real [Downloader] and answers
/// manifest requests through a [MockClient].
@internal
final class ReleaseServer {
  ReleaseServer._(this._server) {
    _server.listen((request) async {
      requests.add(request.uri.path);
      final asset = _assets[request.uri.path];
      if (asset == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.add(asset);
      }
      await request.response.close();
    });
  }

  static Future<ReleaseServer> start() async =>
      ReleaseServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final requests = <String>[];
  final _assets = <String, List<int>>{};
  final _manifests = <String, String>{};
  (int, String)? manifestOverride;

  /// Transient manifest responses served before the real one: a status code
  /// or an exception to throw.
  final manifestFailures = <Object>[];

  String manifestFor(String version) => _manifests['/$version/manifest.json']!;

  String get baseUrl => 'http://${_server.address.host}:${_server.port}';

  late final http.Client manifestClient = MockClient((request) async {
    requests.add(request.url.path);
    if (manifestFailures.isNotEmpty) {
      switch (manifestFailures.removeAt(0)) {
        case final int status:
          return http.Response('busy', status);
        case final Exception error:
          throw error;
      }
    }
    if (manifestOverride case (final status, final body)) {
      return http.Response(body, status);
    }
    final body = _manifests[request.url.path];
    return body == null
        ? http.Response('Not Found', 404)
        : http.Response(body, 200);
  });

  void publish(
    String version,
    IosGenSnapshotMode mode,
    String platform, {
    String? engine,
    ReleaseTamper tamper = ReleaseTamper.none,
    List<int> binary = _binary,
  }) {
    final executable = platform.startsWith('windows')
        ? 'gen_snapshot.exe'
        : 'gen_snapshot';
    final archive = Archive()
      ..add(ArchiveFile.bytes(executable, binary)..mode = 0x1ed)
      ..add(ArchiveFile.bytes('licenses/LICENSE.dart', utf8.encode('BSD')));
    final zip = _unixZip(archive);
    final name = IosGenSnapshotManifest.assetName(mode, platform);
    _assets['/$version/$name'] = zip;
    _manifests['/$version/manifest.json'] = jsonEncode(
      _manifest({
        name: _assetJson(
          tamper == ReleaseTamper.archive ? 'd' * 64 : _sha(zip),
          tamper == ReleaseTamper.executable ? 'e' * 64 : _sha(binary),
          zip.length,
        ),
      }, engine: engine),
    );
  }

  /// Replaces a published compiler with a different build under the same
  /// version, as a fixed release would.
  void republish(
    String version,
    IosGenSnapshotMode mode,
    String platform, {
    required List<int> binary,
  }) => publish(version, mode, platform, binary: binary);

  Future<void> close() => _server.close(force: true);
}

Uint8List _unixZip(Archive archive) {
  final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
  final data = ByteData.sublistView(bytes);
  for (var offset = 0; offset + 6 <= bytes.length; offset++) {
    if (data.getUint32(offset, Endian.little) == 0x02014b50) {
      data.setUint16(offset + 4, 0x0314, Endian.little);
    }
  }
  return bytes;
}
