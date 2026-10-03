import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/device/device_backend.dart';
import 'package:xcross/src/device/internal/signing_session.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/target/iphone/device/signed_bundle_preparer.dart';
import 'package:xcross/src/target/iphone/device/signing_http_client_factory.dart';
import 'package:xcross/src/target/iphone/device/signing_session_resolver.dart';

import 'test_log_output.dart';

void main() {
  late Directory fixture;
  late MacOSHost host;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('device-containment-');
    host = MacOSHost(
      currentDirectory: fixture.path,
      temporaryDirectory: fixture.path,
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  for (final target in [
    'Info.plist',
    'PlugIns',
    'PlugIns/E.appex',
    'PlugIns/E.appex/Info.plist',
  ]) {
    test('rejects linked $target before changing outside bytes', () async {
      final app = Directory(p.join(fixture.path, 'Test.app'))..createSync();
      final outside = Directory(p.join(fixture.path, 'outside'))..createSync();
      final externalPlist = File(p.join(outside.path, 'Info.plist'))
        ..writeAsStringSync('outside immutable bytes');
      File(p.join(app.path, 'Info.plist')).writeAsStringSync(
        '<plist><dict><key>CFBundleIdentifier</key><string>com.test</string></dict></plist>',
      );
      final link = p.join(app.path, target);
      Directory(p.dirname(link)).createSync(recursive: true);
      if (File(link).existsSync()) File(link).deleteSync();
      Link(link).createSync(
        target.endsWith('Info.plist') ? externalPlist.path : outside.path,
      );
      final preparer = SignedBundlePreparer(
        fileSystem: host.fileSystem,
        paths: host.paths,
      );
      await expectLater(
        preparer.rewriteBundleIdentifier(app.path, 'XCR-B.com.test'),
        throwsA(isA<XcrossError>()),
      );
      expect(externalPlist.readAsStringSync(), 'outside immutable bytes');
    });
  }

  test('preserves safe in-root resource links during plist mutation', () async {
    final app = Directory(p.join(fixture.path, 'Safe.app'))..createSync();
    File(p.join(app.path, 'Info.plist')).writeAsStringSync(
      '<plist><dict><key>CFBundleIdentifier</key><string>com.test</string></dict></plist>',
    );
    File(p.join(app.path, 'target.txt')).writeAsStringSync('resource');
    Link(p.join(app.path, 'alias.txt')).createSync('target.txt');
    await SignedBundlePreparer(
      fileSystem: host.fileSystem,
      paths: host.paths,
    ).rewriteBundleIdentifier(app.path, 'XCR-B.com.test');
    expect(
      File(p.join(app.path, 'Info.plist')).readAsStringSync(),
      contains('XCR-B.com.test'),
    );
    expect(File(p.join(app.path, 'alias.txt')).readAsStringSync(), 'resource');
  });

  test(
    'lookup failure closes both signing resources once before any provisioning',
    () async {
      final app = Directory(p.join(fixture.path, 'Test.app'))..createSync();
      final plist = File(p.join(app.path, 'Info.plist'))
        ..writeAsStringSync('untouched');
      final runner = ProcessRunner(host, log: testLog());
      final client = FailingProvisioningClient();
      final anisette = CountingAnisetteProvider();
      final provider = FixedSigningSessionProvider(
        SigningSession(
          client: client,
          anisette: anisette,
          identityId: 'B',
          identityDir: p.join(fixture.path, 'identity'),
        ),
      );
      final backend = NativeBackend(
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
      await expectLater(
        backend.install(
          app.path,
          device: const Device(
            name: 'fixture',
            udid: 'fixture',
            type: ConnectionType.usb,
          ),
          bundleId: 'com.test',
        ),
        throwsA(isA<StateError>()),
      );
      expect(client.lookups, ['com.test']);
      expect(client.closes, 1);
      expect(anisette.closes, 1);
      expect(client.unexpectedCalls, isEmpty);
      expect(plist.readAsStringSync(), 'untouched');
    },
  );
}

final class FixedSigningSessionProvider implements SigningSessionProvider {
  FixedSigningSessionProvider(this.session);
  final SigningSession session;
  @override
  Future<SigningSession> resolve() async => session;
}

final class FailingProvisioningClient implements DevelopmentProvisioningClient {
  final lookups = <String>[];
  final unexpectedCalls = <Symbol>[];
  int closes = 0;
  @override
  Future<AscBundleId?> findBundleId(String identifier) {
    lookups.add(identifier);
    throw StateError('injected lookup failure');
  }

  @override
  void close() => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls.add(invocation.memberName);
    throw StateError('unexpected provisioning call');
  }
}

final class CountingAnisetteProvider implements AnisetteProvider {
  int closes = 0;
  @override
  void close() => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected anisette call');
}
