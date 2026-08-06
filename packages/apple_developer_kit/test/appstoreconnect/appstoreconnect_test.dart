import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/src/appstoreconnect/appstoreconnect.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('wrapDerAsPem', () {
    test('wraps base64 DER content into a line-wrapped PEM block', () {
      final der = base64.encode(List<int>.generate(200, (i) => i % 256));
      final pem = AscProvisioning.wrapDerAsPem(der);

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
      final pem = AscProvisioning.wrapDerAsPem(
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
        final result = await AscProvisioning.provisionDevelopmentIdentity(
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

  test('registers a bundle ID with an alphanumeric display name', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_bundle_name');
    addTearDown(() => temp.deleteSync(recursive: true));
    final client = _FakeProvisioningClient(bundleExists: false);

    await AscProvisioning.provisionDevelopmentIdentity(
      client: client,
      bundleId: 'com.example.my-app',
      deviceUdids: const ['UDID'],
      outputDir: temp.path,
    );

    expect(client.registeredBundleName, 'xcross com example my app');
    expect(client.createdProfileName, matches(r'^xcross Development \d+$'));
  });

  test('revokes team certificates and reissues on create 409', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_cert_409');
    addTearDown(() => temp.deleteSync(recursive: true));
    final client = _FakeProvisioningClient(quotaUsedBy: const ['old-cert']);

    final result = await AscProvisioning.provisionDevelopmentIdentity(
      client: client,
      bundleId: 'com.example.app',
      deviceUdids: const ['UDID'],
      outputDir: temp.path,
    );

    expect(client.revoked, ['old-cert']);
    expect(client.certificateCreations, 2, reason: 'retried after revoking');
    expect(File(result.certificatePemPath).existsSync(), isTrue);
    expect(File(result.privateKeyPemPath).existsSync(), isTrue);
  });

  test('surfaces the 409 when there is nothing to revoke', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_cert_409_empty');
    addTearDown(() => temp.deleteSync(recursive: true));
    final client = _FakeProvisioningClient(pendingRequest: true);

    await expectLater(
      AscProvisioning.provisionDevelopmentIdentity(
        client: client,
        bundleId: 'com.example.app',
        deviceUdids: const ['UDID'],
        outputDir: temp.path,
      ),
      throwsA(isA<AppleApiError>()),
    );
    expect(client.revoked, isEmpty);
    expect(client.certificateCreations, 1, reason: 'no pointless retry');
  });

  test('resolves profile certificate ids by serial like xtool', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_serial_resolve');
    addTearDown(() => temp.deleteSync(recursive: true));
    final client = _FakeProvisioningClient(teamIdForSerial: 'team-side-id');

    await AscProvisioning.provisionDevelopmentIdentity(
      client: client,
      bundleId: 'com.example.app',
      deviceUdids: const ['UDID'],
      outputDir: temp.path,
    );

    expect(client.lastProfileCertificateIds, ['team-side-id']);
  });

  test('deletes the sole existing profile before creating a new one', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_profile_replace');
    addTearDown(() => temp.deleteSync(recursive: true));
    final client = _FakeProvisioningClient(
      existingProfileIds: const ['old-profile'],
    );

    await AscProvisioning.provisionDevelopmentIdentity(
      client: client,
      bundleId: 'com.example.app',
      deviceUdids: const ['UDID'],
      outputDir: temp.path,
    );

    expect(client.deletedProfiles, ['old-profile']);
  });

  test('attaches every iOS device on the team to the profile', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_all_devices');
    addTearDown(() => temp.deleteSync(recursive: true));
    final client = _FakeProvisioningClient(
      extraDevices: const [
        AscDevice(
          id: 'ipad',
          udid: 'IPAD-UDID',
          name: 'iPad',
          status: 'ENABLED',
          deviceClass: 'IPAD',
        ),
        AscDevice(
          id: 'mac',
          udid: 'MAC-UDID',
          name: 'Mac',
          status: 'ENABLED',
          deviceClass: 'MAC',
        ),
      ],
    );

    await AscProvisioning.provisionDevelopmentIdentity(
      client: client,
      bundleId: 'com.example.app',
      deviceUdids: const ['UDID'],
      outputDir: temp.path,
    );

    expect(
      client.lastProfileDeviceIds,
      unorderedEquals(['device-UDID', 'ipad']),
    );
  });
}

class _FakeProvisioningClient implements DevelopmentProvisioningClient {
  _FakeProvisioningClient({
    this.bundleExists = true,
    this.quotaUsedBy = const [],
    this.pendingRequest = false,
    this.teamIdForSerial,
    this.existingProfileIds = const [],
    this.extraDevices = const [],
  });

  final bool bundleExists;
  final List<String> quotaUsedBy;
  final bool pendingRequest;
  final String? teamIdForSerial;
  final List<String> existingProfileIds;
  final List<AscDevice> extraDevices;

  final revoked = <String>[];
  final deletedProfiles = <String>[];
  final teamSerials = <String, String>{};
  int certificateCreations = 0;
  String? registeredBundleName;
  String? createdProfileName;
  List<String>? lastProfileCertificateIds;
  List<String>? lastProfileDeviceIds;

  @override
  Future<AscCertificate> createDevelopmentCertificate({
    required String csrPem,
  }) async {
    certificateCreations++;
    if (pendingRequest || quotaUsedBy.any((id) => !revoked.contains(id))) {
      throw const AppleApiError(
        409,
        'You already have a current Development certificate or a pending '
        'certificate request.',
      );
    }
    final id = 'certificate-id-$certificateCreations';
    final serial = 'SERIAL$certificateCreations';
    teamSerials[serial] = teamIdForSerial ?? id;
    return AscCertificate(
      id: id,
      certificateContentBase64: base64Encode([1, 2, 3]),
      expirationDate: DateTime.now()
          .toUtc()
          .add(const Duration(days: 1))
          .toIso8601String(),
      serialNumber: serial,
    );
  }

  @override
  Future<AscBundleId?> findBundleId(String identifier) async => bundleExists
      ? AscBundleId(
          id: 'bundle-$identifier',
          identifier: identifier,
          name: identifier,
        )
      : null;

  @override
  Future<AscDevice?> findDeviceByUdid(String udid) async => AscDevice(
    id: 'device-$udid',
    udid: udid,
    name: udid,
    status: 'ENABLED',
    deviceClass: 'IPHONE',
  );

  @override
  Future<AscProfile> createProfile({
    required String name,
    required String bundleIdResourceId,
    required List<String> certificateResourceIds,
    required List<String> deviceResourceIds,
  }) async {
    lastProfileCertificateIds = List.of(certificateResourceIds);
    lastProfileDeviceIds = List.of(deviceResourceIds);
    createdProfileName = name;
    return AscProfile(
      id: 'profile-$bundleIdResourceId',
      profileContentBase64: base64Encode([4, 5, 6]),
      uuid: 'uuid',
      profileState: 'ACTIVE',
      expirationDate: null,
    );
  }

  @override
  Future<List<String>> listCertificateIds() async => [
    for (final id in quotaUsedBy)
      if (!revoked.contains(id)) id,
  ];

  @override
  Future<List<String>> findCertificateIdsBySerial(String serialNumber) async {
    final id = teamSerials[serialNumber];
    if (id == null || revoked.contains(id)) return const [];
    return [id];
  }

  @override
  Future<void> revokeCertificate(String certificateId) async {
    revoked.add(certificateId);
    teamSerials.removeWhere((_, id) => id == certificateId);
  }

  @override
  Future<List<AscDevice>> listDevices() async => [
    const AscDevice(
      id: 'device-UDID',
      udid: 'UDID',
      name: 'UDID',
      status: 'ENABLED',
      deviceClass: 'IPHONE',
    ),
    ...extraDevices,
  ];

  @override
  Future<List<String>> listProfileIdsForBundle(
    String bundleIdResourceId,
  ) async => [
    for (final id in existingProfileIds)
      if (!deletedProfiles.contains(id)) id,
  ];

  @override
  Future<void> deleteProfile(String profileId) async =>
      deletedProfiles.add(profileId);

  @override
  Future<AscBundleId> registerBundleId({
    required String identifier,
    required String name,
  }) async {
    registeredBundleName = name;
    return AscBundleId(
      id: 'bundle-$identifier',
      identifier: identifier,
      name: name,
    );
  }

  @override
  Future<AscDevice> registerDevice({
    required String udid,
    required String name,
  }) => throw UnimplementedError();

  @override
  void close() {}
}
