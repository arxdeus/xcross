import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/composition/apple_host.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_provider.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_privileges.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:dart_mobile_device/host/macos/macos_device_host.dart';
import 'package:dart_mobile_device/shared/device/models/device.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/auth/signing_availability.dart';
import 'package:xcross/src/shared/auth/signing_session.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/iphone/device/device_backend.dart';
import 'package:xcross/src/target/iphone/device/signing_http_client_factory.dart';
import 'package:xcross/src/target/iphone/device/signing_session_resolver.dart';

import 'test_log_output.dart';

void main() {
  group('connectivity classification', () {
    for (final error in <Object>[
      const SocketException('Failed host lookup'),
      http.ClientException('Connection refused'),
      const TlsException('handshake'),
      const HttpException('closed'),
      TimeoutException('slow'),
      const AppleApiError(503, 'unavailable'),
    ]) {
      test('treats ${error.runtimeType} as unreachable', () {
        expect(SigningServiceUnavailable.isConnectivityFailure(error), isTrue);
      });
    }

    for (final error in <Object>[
      const AppleApiError(401, 'unauthorized'),
      const AppleApiError(409, 'conflict'),
      StateError('bug'),
      XcrossError('user facing'),
    ]) {
      test('surfaces $error instead of signing offline', () {
        expect(SigningServiceUnavailable.isConnectivityFailure(error), isFalse);
      });
    }
  });

  group('profile device coverage', () {
    test('matches a listed device case-insensitively', () {
      expect(
        NativeBackend.profileCoversDevice({
          'ProvisionedDevices': ['00008110-000A1B2C3D4E5F6A'],
        }, '00008110-000a1b2c3d4e5f6a'),
        isTrue,
      );
    });
    test('rejects a device the profile does not list', () {
      expect(
        NativeBackend.profileCoversDevice({
          'ProvisionedDevices': ['OTHER'],
        }, 'U1'),
        isFalse,
      );
      expect(NativeBackend.profileCoversDevice(const {}, 'U1'), isFalse);
    });
    test('accepts an all-devices profile', () {
      expect(
        NativeBackend.profileCoversDevice({'ProvisionsAllDevices': true}, 'U1'),
        isTrue,
      );
    });
  });

  group('offline install', () {
    late Directory fixture;
    late MacOSHost host;
    late NativeBackend Function(SigningSessionProvider) backendFor;
    late String app;
    const identity = SigningIdentity(identityId: 'TEAM1', identityDir: '');

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('offline-install-');
      host = MacOSHost(
        environment: {'HOME': fixture.path},
        currentDirectory: fixture.path,
        temporaryDirectory: fixture.path,
      );
      app = p.join(fixture.path, 'Runner.app');
      Directory(app).createSync();
      File(p.join(app, 'Info.plist')).writeAsStringSync(
        '<plist><dict><key>CFBundleIdentifier</key>'
        '<string>com.example.app</string></dict></plist>',
      );
      final runner = ProcessRunner(
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
        host,
        log: testLog(),
      );
      backendFor = (provider) => NativeBackend(
        Pymd(
          runner,
          hostPolicy: MacOSDeviceHost(runner),
          privileges: PosixPrivileges(runner),
          console: TestDeviceConsole(),
          localHttp: testLocalHttp(),
        ),
        hostServices: createMacOSAppleHostServices(
          host,
          runner: runner,
          localeName: 'en_US',
          abi: Abi.macosArm64,
        ),
        createNativeLibraryLoader: () =>
            throw StateError('unexpected native loading'),
        httpClients: const HttpSigningClientFactory(),
        signingSessions: provider,
      );
    });
    tearDown(() => fixture.deleteSync(recursive: true));

    SigningIdentity identityIn(String root) => SigningIdentity(
      identityId: identity.identityId,
      identityDir: p.join(root, 'signing', 'developer-services-TEAM1', 'id'),
    );

    const device = Device(name: 'Phone', udid: 'U1', type: ConnectionType.usb);

    test(
      testOn: '!windows',
      'without a cached profile explains how to get one',
      () async {
        final provider = ThrowingSigningSessionProvider(
          SigningServiceUnavailable.unreachable(
            const SocketException('Failed host lookup'),
            identity: identityIn(fixture.path),
          ),
        );
        await expectLater(
          backendFor(
            provider,
          ).install(app, device: device, bundleId: 'com.example.app'),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('unreachable'),
                contains('No cached signing profile for "com.example.app"'),
                contains('Run once while connected'),
              ),
            ),
          ),
        );
      },
    );

    test(
      testOn: '!windows',
      'picks the qualified App ID the last online run cached',
      () async {
        final signing = identityIn(fixture.path);
        // Only the qualified id was provisioned, so offline must sign as it;
        // the half-written cache (no cert/key) then stops it before signing.
        final profile = File(
          p.join(
            signing.profilesDir,
            'XCR-TEAM1.com.example.app',
            'profile.mobileprovision',
          ),
        )..createSync(recursive: true);
        await expectLater(
          backendFor(
            ThrowingSigningSessionProvider(
              SigningServiceUnavailable.unreachable(
                const SocketException('offline'),
                identity: signing,
              ),
            ),
          ).install(app, device: device, bundleId: 'com.example.app'),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              contains('"XCR-TEAM1.com.example.app"'),
            ),
          ),
        );
        expect(profile.existsSync(), isTrue);
        expect(
          File(p.join(app, 'Info.plist')).readAsStringSync(),
          contains('XCR-TEAM1.com.example.app'),
        );
      },
    );

    test(
      testOn: '!windows',
      'honours a saved prefixed App ID choice offline',
      () async {
        final signing = identityIn(fixture.path);
        for (final id in ['com.example.app', 'XCR-TEAM1.com.example.app']) {
          File(
            p.join(signing.profilesDir, id, 'profile.mobileprovision'),
          ).createSync(recursive: true);
        }
        File(
          p.join(fixture.path, 'xcross_project.yaml'),
        ).writeAsStringSync('bundle_id: prefixed\n');
        await expectLater(
          backendFor(
            ThrowingSigningSessionProvider(
              SigningServiceUnavailable.unreachable(
                const SocketException('offline'),
                identity: signing,
              ),
            ),
          ).install(
            app,
            device: device,
            bundleId: 'com.example.app',
            projectRoot: fixture.path,
          ),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              contains('"XCR-TEAM1.com.example.app"'),
            ),
          ),
        );
      },
    );

    test(
      testOn: '!windows',
      'lookup that cannot reach Apple falls back offline',
      () async {
        final client = UnreachableProvisioningClient();
        final anisette = ClosingAnisetteProvider();
        final signing = identityIn(fixture.path);
        await expectLater(
          backendFor(
            FixedSession(
              SigningSession(
                client: client,
                anisette: anisette,
                identityId: signing.identityId,
                identityDir: signing.identityDir,
              ),
            ),
          ).install(app, device: device, bundleId: 'com.example.app'),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('unreachable'),
                contains('No cached signing profile'),
              ),
            ),
          ),
        );
        expect(client.closes, 1);
        expect(anisette.closes, 1);
      },
    );

    test(
      testOn: '!windows',
      'without any saved account keeps the original error',
      () async {
        await expectLater(
          backendFor(
            ThrowingSigningSessionProvider(
              SigningServiceUnavailable(
                reason: 'r',
                message: 'nothing to fall back on',
                identity: null,
              ),
            ),
          ).install(app, device: device, bundleId: 'com.example.app'),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              'nothing to fall back on',
            ),
          ),
        );
      },
    );
  });

  group('resolver', () {
    late Directory fixture;
    setUp(() => fixture = Directory.systemTemp.createTempSync('resolver-'));
    tearDown(() => fixture.deleteSync(recursive: true));

    SigningSessionResolver resolverWith(Map<String, String> environment) {
      final host = MacOSHost(
        environment: {'HOME': fixture.path, ...environment},
        currentDirectory: fixture.path,
        temporaryDirectory: fixture.path,
      );
      final runner = ProcessRunner(
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
        host,
        log: testLog(),
      );
      return SigningSessionResolver(
        hostServices: createMacOSAppleHostServices(
          host,
          runner: runner,
          localeName: 'en_US',
          abi: Abi.macosArm64,
        ),
        httpClients: const ThrowingHttpClients(),
        createNativeLibraryLoader: () =>
            throw StateError('unexpected native loading'),
      );
    }

    test(
      testOn: '!windows',
      'XCROSS_OFFLINE uses saved ASC credentials without HTTP',
      () async {
        final config = File(
          p.join(fixture.path, '.config', 'xcross', 'appstoreconnect.json'),
        )..createSync(recursive: true);
        config.writeAsStringSync(
          '{"issuerId": "abcd-1234", "keyId": "K", "privateKeyPath": "/k.p8"}',
        );
        await expectLater(
          resolverWith({SigningSessionResolver.offlineEnvVar: '1'}).resolve(),
          throwsA(
            isA<SigningServiceUnavailable>()
                .having(
                  (error) => error.identity?.identityId,
                  'id',
                  'abcd-1234',
                )
                .having(
                  (error) => error.identity?.identityDir,
                  'dir',
                  endsWith(p.join('appstoreconnect-abcd-1234', 'identity')),
                ),
          ),
        );
      },
    );

    test('XCROSS_OFFLINE with no saved account is a plain error', () async {
      await expectLater(
        resolverWith({SigningSessionResolver.offlineEnvVar: '1'}).resolve(),
        throwsA(isA<XcrossError>()),
      );
    });
  });
}

@internal
final class ThrowingSigningSessionProvider implements SigningSessionProvider {
  ThrowingSigningSessionProvider(this.error);
  final SigningServiceUnavailable error;
  @override
  Future<SigningSession> resolve() async => throw error;
}

@internal
final class FixedSession implements SigningSessionProvider {
  FixedSession(this.session);
  final SigningSession session;
  @override
  Future<SigningSession> resolve() async => session;
}

@internal
final class UnreachableProvisioningClient
    implements DevelopmentProvisioningClient {
  int closes = 0;
  @override
  Future<Never> findBundleId(String identifier) =>
      throw const SocketException('Network is unreachable');
  @override
  void close() => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected provisioning call');
}

@internal
final class ClosingAnisetteProvider implements AnisetteProvider {
  int closes = 0;
  @override
  void close() => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected anisette call');
}

@internal
final class ThrowingHttpClients implements SigningHttpClientFactory {
  const ThrowingHttpClients();
  @override
  http.Client create() => throw StateError('offline mode must not use HTTP');
}
