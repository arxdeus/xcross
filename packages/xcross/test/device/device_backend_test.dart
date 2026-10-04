import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:apple_developer_kit/composition/apple_host.dart';
import 'package:apple_developer_kit/shared/adi/apk_fetch.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_provider.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/shared/grandslam/app_token_exchange.dart';
import 'package:apple_developer_kit/shared/grandslam/grandslam_session_store.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_privileges.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:dart_mobile_device/host/macos/macos_device_host.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/iphone/device/device_backend.dart';
import 'package:xcross/src/target/iphone/device/signing_http_client_factory.dart';
import 'package:xcross/src/target/iphone/device/signing_session_resolver.dart';

import 'test_log_output.dart';

void main() {
  final runner = ProcessRunner(
    stdinStream: const Stream.empty(),
    stdoutSink: testSink(),
    stderrSink: testSink(),
    MacOSHost(),
    log: testLog(),
  );
  group('saved Apple ID session provider', () {
    final directory = p.join(Directory.systemTemp.absolute.path, 'adi-fixture');

    for (final abi in const [
      Abi.linuxX64,
      Abi.linuxArm64,
      Abi.macosX64,
      Abi.macosArm64,
      Abi.windowsX64,
    ]) {
      test('uses the saved ADI directory on $abi without IO', () {
        final provider = NoIoAnisetteProvider();
        final directories = <String>[];
        final resolved = SigningSessionResolver.anisetteForSession(
          _session(directory),
          hostAbi: abi,
          createProvider: (path) {
            directories.add(path);
            return provider;
          },
        );
        expect(resolved, same(provider));
        expect(directories, [directory]);
      });

      test('preserves the missing-directory error on $abi', () {
        expect(
          () => SigningSessionResolver.anisetteForSession(
            _session(null),
            hostAbi: abi,
            createProvider: (_) => fail('Must reject before creating provider'),
          ),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              'Saved Apple ID session is missing adiLibraryDirectory. '
                  'Run xcross auth --apple-id <email> again.',
            ),
          ),
        );
      });
    }

    for (final abi in const [
      Abi.windowsArm64,
      Abi.linuxArm,
      Abi.androidArm64,
    ]) {
      for (final path in [directory, null]) {
        test('preflights unsupported $abi with directory $path', () {
          expect(
            () => SigningSessionResolver.anisetteForSession(
              _session(path),
              hostAbi: abi,
              createProvider: (_) =>
                  fail('Must reject before creating provider'),
            ),
            throwsA(
              isA<XcrossError>().having(
                (error) => error.message,
                'message',
                'Saved native Apple ID sessions support Linux and macOS x64/ARM64 '
                    'and Windows x64 (got $abi).',
              ),
            ),
          );
        });
      }
    }

    test('uses explicitly supplied ABI', () {
      final provider = NoIoAnisetteProvider();
      AnisetteProvider resolve() => SigningSessionResolver.anisetteForSession(
        _session(directory),
        hostAbi: Abi.macosArm64,
        createProvider: (_) => provider,
      );
      if (AdiLibraryFetcher.supportsAbi(Abi.macosArm64)) {
        expect(resolve(), same(provider));
      } else {
        expect(resolve, throwsA(isA<XcrossError>()));
      }
    });
  });

  test('always resolves the native backend', () async {
    expect(
      await DeviceBackend.resolve(
        Pymd(
          console: TestDeviceConsole(),
          localHttp: testLocalHttp(),
          runner,
          privileges: PosixPrivileges(runner),
          hostPolicy: MacOSDeviceHost(runner),
        ),
        hostServices: createMacOSAppleHostServices(
          runner.host as MacOSHostInterface,
          runner: runner,
          localeName: 'en_US',
          abi: Abi.macosArm64,
        ),
        httpClients: const HttpSigningClientFactory(),
        createNativeLibraryLoader: () =>
            throw StateError('no native loading in test'),
      ),
      isA<NativeBackend>(),
    );
  });

  test('rejects non-app inputs before provisioning mutates Apple state', () {
    final uri = Isolate.resolvePackageUriSync(
      Uri.parse('package:xcross/src/target/iphone/device/device_backend.dart'),
    )!;
    final source = File.fromUri(uri).readAsStringSync();
    final guard = source.indexOf(
      'in-process signer currently supports xcross-generated .app',
    );
    final provision = source.indexOf('await AscProvisioning(');

    expect(guard, greaterThanOrEqualTo(0));
    expect(provision, greaterThan(guard));
    expect(source, isNot(contains('ZsignCli')));
  });
}

GrandSlamSession _session(String? directory) => GrandSlamSession(
  username: 'fixture@example.invalid',
  token: DeveloperServicesLoginToken(
    adsid: 'fixture',
    token: 'not-a-real-token',
    expiry: DateTime.utc(2099),
  ),
  teamId: 'FIXTURE',
  adiLibraryDirectory: directory,
);

@internal
final class NoIoAnisetteProvider implements AnisetteProvider {
  @override
  Future<Map<String, String>> fetchAnisetteHeaders() =>
      throw StateError('Provider construction must not fetch headers');

  @override
  Future<GrandSlamEndpoints> resolveGrandSlamEndpoints() =>
      throw StateError('Provider construction must not resolve endpoints');

  @override
  void close() {}
}
