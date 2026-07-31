import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/appstoreconnect/appstoreconnect.dart';

void main() {
  group('wrapDerAsPem', () {
    test('wraps base64 DER content into a line-wrapped PEM block', () {
      final der = base64.encode(List<int>.generate(200, (i) => i % 256));
      final pem = wrapDerAsPem(der);

      expect(pem, startsWith('-----BEGIN CERTIFICATE-----\n'));
      expect(pem, endsWith('-----END CERTIFICATE-----\n'));

      final lines = pem.trim().split('\n');
      final bodyLines = lines.sublist(1, lines.length - 1);
      for (final line in bodyLines.sublist(0, bodyLines.length - 1)) {
        expect(line.length, 64);
      }

      // Round-trips back to the original DER bytes.
      expect(base64.decode(bodyLines.join()), base64.decode(der));
    });

    test('supports a custom label', () {
      final pem = wrapDerAsPem(
        base64.encode([1, 2, 3]),
        label: 'RSA PRIVATE KEY',
      );
      expect(pem, startsWith('-----BEGIN RSA PRIVATE KEY-----\n'));
      expect(pem, contains('-----END RSA PRIVATE KEY-----'));
    });
  });

  test(
    'shares one certificate identity across bundle profile directories',
    () async {
      final temp = Directory.systemTemp.createTempSync('xcross_identity_cache');
      addTearDown(() => temp.deleteSync(recursive: true));
      final client = _FakeProvisioningClient();
      final identityDir = p.join(temp.path, 'identity');

      for (final bundleId in ['com.example.one', 'com.example.two']) {
        final result = await provisionDevelopmentIdentity(
          client: client,
          bundleId: bundleId,
          deviceUdids: const ['UDID'],
          outputDir: p.join(temp.path, 'profiles', bundleId),
          identityDir: identityDir,
        );
        expect(File(result.certificatePemPath).parent.path, identityDir);
        expect(
          File(result.profilePath).parent.path,
          p.join(temp.path, 'profiles', bundleId),
        );
      }

      expect(client.certificateCreations, 1);
    },
  );
}

class _FakeProvisioningClient implements DevelopmentProvisioningClient {
  int certificateCreations = 0;

  @override
  Future<AscCertificate> createDevelopmentCertificate({
    required String csrPem,
  }) async {
    certificateCreations++;
    return AscCertificate(
      id: 'certificate-id',
      certificateContentBase64: base64Encode([1, 2, 3]),
      expirationDate: DateTime.now()
          .toUtc()
          .add(const Duration(days: 1))
          .toIso8601String(),
      serialNumber: 'serial',
    );
  }

  @override
  Future<AscBundleId?> findBundleId(String identifier) async => AscBundleId(
    id: 'bundle-$identifier',
    identifier: identifier,
    name: identifier,
  );

  @override
  Future<AscDevice?> findDeviceByUdid(String udid) async =>
      AscDevice(id: 'device-$udid', udid: udid, name: udid, status: 'ENABLED');

  @override
  Future<AscProfile> createProfile({
    required String name,
    required String bundleIdResourceId,
    required List<String> certificateResourceIds,
    required List<String> deviceResourceIds,
  }) async => AscProfile(
    id: 'profile-$bundleIdResourceId',
    profileContentBase64: base64Encode([4, 5, 6]),
    uuid: 'uuid',
    profileState: 'ACTIVE',
    expirationDate: null,
  );

  @override
  Future<List<AscDevice>> listDevices() async => const [];

  @override
  Future<AscBundleId> registerBundleId({
    required String identifier,
    required String name,
  }) => throw UnimplementedError();

  @override
  Future<AscDevice> registerDevice({
    required String udid,
    required String name,
  }) => throw UnimplementedError();

  @override
  void close() {}
}
