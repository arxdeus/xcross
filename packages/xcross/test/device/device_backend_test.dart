import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:apple_developer_kit/composition/apple_host.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_data_provider.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_provider.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/omnisette_provider.dart';
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

    AnisetteProvider resolve(
      GrandSlamSession session, {
      Abi hostAbi = Abi.macosArm64,
      String? anisetteUrlOverride,
    }) => SigningSessionResolver.anisetteForSession(
      session,
      hostAbi: hostAbi,
      anisetteUrlOverride: anisetteUrlOverride,
      createAndroidProvider: RecordingAnisetteProvider.new,
      createOmnisetteProvider: RecordingAnisetteProvider.new,
    );

    test('uses the saved ADI directory for recorded local sessions', () {
      final provider = resolve(
        _session(directory, anisetteProvider: kAdiProviderId),
      );
      expect(provider, isA<RecordingAnisetteProvider>());
      expect((provider as RecordingAnisetteProvider).argument, directory);
    });

    test('legacy sessions with an ADI directory stay local', () {
      final provider = resolve(_session(directory));
      expect((provider as RecordingAnisetteProvider).argument, directory);
    });

    test('uses the recorded Omnisette URL for remote sessions', () {
      final provider = resolve(
        _session(null, anisetteProvider: kOmnisetteProviderId, url: 'https://om.example.test'),
      );
      expect((provider as RecordingAnisetteProvider).argument, 'https://om.example.test');
    });

    test('omnisette-only-build sessions without a directory go remote', () {
      final provider = resolve(_session(null));
      expect(
        (provider as RecordingAnisetteProvider).argument,
        kDefaultOmnisetteUrl,
      );
    });

    test('XCROSS_ANISETTE_URL redirects a remote session', () {
      final provider = resolve(
        _session(null, anisetteProvider: kOmnisetteProviderId, url: 'https://om.example.test'),
        anisetteUrlOverride: 'https://self.example.test',
      );
      expect(
        (provider as RecordingAnisetteProvider).argument,
        'https://self.example.test',
      );
    });

    test('XCROSS_ANISETTE_URL never reroutes a local session', () {
      final provider = resolve(
        _session(directory, anisetteProvider: kAdiProviderId),
        anisetteUrlOverride: 'https://om.example.test',
      );
      expect((provider as RecordingAnisetteProvider).argument, directory);
    });

    test('unknown recorded providers are refused', () {
      expect(
        () => resolve(_session(directory, anisetteProvider: 'future-thing')),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('unknown anisette provider "future-thing"'),
          ),
        ),
      );
    });

    for (final abi in const [Abi.windowsIA32, Abi.linuxArm, Abi.androidArm64]) {
      test('preflights unsupported local $abi', () {
        expect(
          () => resolve(_session(directory), hostAbi: abi),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              'Saved native Apple ID sessions support Linux and macOS x64/ARM64 '
                  'and Windows x64/ARM64 (got $abi).',
            ),
          ),
        );
      });
    }

    test('local sessions still need a directory', () {
      expect(
        () => resolve(_session(null, anisetteProvider: kAdiProviderId)),
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

GrandSlamSession _session(
  String? directory, {
  String? anisetteProvider,
  String? url,
}) => GrandSlamSession(
  username: 'fixture@example.invalid',
  token: DeveloperServicesLoginToken(
    adsid: 'fixture',
    token: 'not-a-real-token',
    expiry: DateTime.utc(2099),
  ),
  teamId: 'FIXTURE',
  anisetteProvider: anisetteProvider,
  anisetteUrl: url,
  adiLibraryDirectory: directory,
);

@internal
final class RecordingAnisetteProvider implements AnisetteProvider {
  RecordingAnisetteProvider(this.argument);

  final String argument;

  @override
  Future<Map<String, String>> fetchAnisetteHeaders() =>
      throw StateError('Provider construction must not fetch headers');

  @override
  Future<GrandSlamEndpoints> resolveGrandSlamEndpoints() =>
      throw StateError('Provider construction must not resolve endpoints');

  @override
  void close() {}
}
