/// App Store Connect API client for provisioning iOS Development signing
/// (certificates, devices, bundle ids, profiles) using only a Team-scoped
/// API key - no interactive Apple ID / GrandSlam login.
library;

import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/src/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_csr.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_models.dart';
import 'package:apple_developer_kit/src/appstoreconnect/provisioning_identifiers.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:path/path.dart' as p;
export 'asc_client.dart';
export 'asc_config.dart';
export 'asc_csr.dart';
export 'asc_jwt.dart';
export 'asc_models.dart';
export 'developer_services_client.dart';
export 'provisioning_identifiers.dart';

/// Development identity provisioning against App Store Connect.
abstract final class AscProvisioning {
  /// Wraps [derBase64] (base64-encoded DER, as returned raw by the
  /// certificates API's `certificateContent`) into a line-wrapped PEM block.
  ///
  /// The API does NOT return PEM directly - dumping `certificateContent` to a
  /// `.pem` file as-is produces an invalid certificate.
  static String wrapDerAsPem(String derBase64, {String label = 'CERTIFICATE'}) {
    final der = base64.decode(derBase64);
    final body = base64.encode(der);
    final buffer = StringBuffer('-----BEGIN $label-----\n');
    for (var i = 0; i < body.length; i += 64) {
      final end = i + 64 < body.length ? i + 64 : body.length;
      buffer.writeln(body.substring(i, end));
    }
    buffer.write('-----END $label-----\n');
    return buffer.toString();
  }

  /// Runs the full Development-signing provisioning flow against [client].
  ///
  /// Mirrors xtool's `DeveloperServicesFetchCertificateOperation` +
  /// `DeveloperServicesFetchProfileOperation`:
  /// 1. Reuse a local identity whose serial is still on the team, otherwise
  ///    revoke existing team certificates and issue a new `DEVELOPMENT` /
  ///    `IOS_DEVELOPMENT` cert.
  /// 2. Find-or-register [bundleId] and each of [deviceUdids].
  /// 3. If the bundle already has exactly one profile, delete it (free-team
  ///    slot).
  /// 4. Resolve the cert's team-side id by serial (never trust create-response
  ///    id alone), attach every iOS-capable device on the team, and create an
  ///    `IOS_APP_DEVELOPMENT` profile.
  static Future<
    ({String certificatePemPath, String privateKeyPemPath, String profilePath})
  >
  provisionDevelopmentIdentity({
    required DevelopmentProvisioningClient client,
    required String bundleId,
    required List<String> deviceUdids,
    required String outputDir,
    String? identityDir,
    void Function(String message)? onProgress,
  }) async {
    final signingIdentityDir = identityDir ?? outputDir;
    await Future.wait([
      Directory(outputDir).create(recursive: true),
      Directory(signingIdentityDir).create(recursive: true),
    ]);

    final certPath = p.join(signingIdentityDir, 'cert.pem');
    final keyPath = p.join(signingIdentityDir, 'key.pem');
    final statePath = p.join(signingIdentityDir, 'state.json');
    final profilePath = p.join(outputDir, 'profile.mobileprovision');

    final identity = await _loadOrIssueIdentity(
      client: client,
      certPath: certPath,
      keyPath: keyPath,
      statePath: statePath,
      onProgress: onProgress,
    );

    final bundleIdResource =
        await client.findBundleId(bundleId) ??
        await client.registerBundleId(
          identifier: bundleId,
          name: ProvisioningIdentifiers.appName(bundleId),
        );

    for (final udid in deviceUdids) {
      await client.findDeviceByUdid(udid) ??
          await client.registerDevice(udid: udid, name: udid);
    }

    // xtool: if the bundle already has exactly one profile, delete it before
    // creating a fresh one (free teams are limited; paid teams with >1 are left
    // alone).
    final existingProfiles = await client.listProfileIdsForBundle(
      bundleIdResource.id,
    );
    if (existingProfiles.length == 1) {
      await client.deleteProfile(existingProfiles.single);
    }

    final certificateIds = await client.findCertificateIdsBySerial(
      identity.serialNumber,
    );
    if (certificateIds.isEmpty) {
      throw AppleError(
        'Development certificate serial ${identity.serialNumber} is not on '
        'the team after issuance. Run xcross auth again, or revoke stale '
        'certificates at developer.apple.com.',
      );
    }

    // xtool attaches every iPhone/iPad/iPod on the team, not just the current
    // UDID — Apple's profile create is picky about device membership.
    final deviceResourceIds = {
      for (final device in await client.listDevices())
        if (device.supportsIosApps || deviceUdids.contains(device.udid))
          device.id,
    }.toList();
    if (deviceResourceIds.isEmpty) {
      throw AppleError(
        'No iOS devices are registered on this team. Plug in a device and '
        'retry.',
      );
    }

    final profile = await client.createProfile(
      name: 'xcross Development ${DateTime.now().microsecondsSinceEpoch}',
      bundleIdResourceId: bundleIdResource.id,
      certificateResourceIds: certificateIds,
      deviceResourceIds: deviceResourceIds,
    );
    await File(
      profilePath,
    ).writeAsBytes(base64.decode(profile.profileContentBase64));

    return (
      certificatePemPath: certPath,
      privateKeyPemPath: keyPath,
      profilePath: profilePath,
    );
  }

  /// xtool `DeveloperServicesFetchCertificateOperation.perform`:
  /// reuse local identity when its serial is still on the team and unexpired;
  /// otherwise revoke team certificates and create a new one.
  static Future<_SigningIdentity> _loadOrIssueIdentity({
    required DevelopmentProvisioningClient client,
    required String certPath,
    required String keyPath,
    required String statePath,
    void Function(String message)? onProgress,
  }) async {
    final cached = await _cachedIdentity(statePath, certPath, keyPath);
    if (cached != null) {
      final ids = await client.findCertificateIdsBySerial(cached.serialNumber);
      if (ids.isNotEmpty) return cached;
      onProgress?.call(
        'Cached Development certificate serial ${cached.serialNumber} is '
        'gone from the team; revoking leftovers and re-issuing.',
      );
      await _revokeAllCertificates(client, onProgress: onProgress);
    }
    return _issueAndPersistIdentity(
      client: client,
      certPath: certPath,
      keyPath: keyPath,
      statePath: statePath,
      onProgress: onProgress,
    );
  }

  static Future<_SigningIdentity> _issueAndPersistIdentity({
    required DevelopmentProvisioningClient client,
    required String certPath,
    required String keyPath,
    required String statePath,
    void Function(String message)? onProgress,
  }) async {
    final csr = AscCsr.generate();
    final certificate = await _issueDevelopmentCertificate(
      client,
      csr.csrPem,
      onProgress: onProgress,
    );
    await File(certPath).writeAsString(
      AscProvisioning.wrapDerAsPem(certificate.certificateContentBase64),
    );
    await AscCsr.writePrivateKeyPem(
      keyPath,
      AscCsr.privateKeyToPem(csr.privateKey),
    );
    final serialNumber =
        certificate.serialNumber ??
        AscProvisioning.serialNumberFromCertificatePem(
          await File(certPath).readAsString(),
        );
    await File(statePath).writeAsString(
      jsonEncode({
        'certificateId': certificate.id,
        'certificateSerialNumber': serialNumber,
        'certificateExpirationDate': certificate.expirationDate,
      }),
    );
    return _SigningIdentity(serialNumber: serialNumber);
  }

  /// Issues a Development certificate. On HTTP 409 (quota), revoke every
  /// certificate on the team first — same as xtool's free-team
  /// `replaceCertificates`.
  static Future<AscCertificate> _issueDevelopmentCertificate(
    DevelopmentProvisioningClient client,
    String csrPem, {
    void Function(String message)? onProgress,
  }) async {
    try {
      return await client.createDevelopmentCertificate(csrPem: csrPem);
    } on AppleApiError catch (error) {
      if (error.statusCode != 409) rethrow;
      final existing = await client.listCertificateIds();
      if (existing.isEmpty) rethrow;
      await _revokeAllCertificates(
        client,
        knownIds: existing,
        onProgress: onProgress,
      );
      return client.createDevelopmentCertificate(csrPem: csrPem);
    }
  }

  static Future<void> _revokeAllCertificates(
    DevelopmentProvisioningClient client, {
    List<String>? knownIds,
    void Function(String message)? onProgress,
  }) async {
    final ids = knownIds ?? await client.listCertificateIds();
    for (final id in ids) {
      onProgress?.call(
        'Revoking certificate $id: its private key is not on this machine. '
        'Apps still signed with it must be re-signed.',
      );
      await client.revokeCertificate(id);
    }
  }

  /// Returns the cached identity when [certPath]/[keyPath] exist and the
  /// certificate isn't expired, else null.
  static Future<_SigningIdentity?> _cachedIdentity(
    String statePath,
    String certPath,
    String keyPath,
  ) async {
    if (!File(statePath).existsSync() ||
        !File(certPath).existsSync() ||
        !File(keyPath).existsSync()) {
      return null;
    }
    try {
      final state = jsonDecode(await File(statePath).readAsString());
      if (state is! Map) return null;
      final expirationDate = state['certificateExpirationDate'] as String?;
      final expiry = expirationDate == null
          ? null
          : DateTime.tryParse(expirationDate);
      if (expiry == null || !expiry.toUtc().isAfter(DateTime.now().toUtc())) {
        return null;
      }
      final serial =
          state['certificateSerialNumber'] as String? ??
          AscProvisioning.serialNumberFromCertificatePem(
            await File(certPath).readAsString(),
          );
      if (serial.isEmpty) return null;
      return _SigningIdentity(serialNumber: serial);
    } on FormatException {
      return null;
    } on Object {
      return null;
    }
  }

  /// Apple's `filter[serialNumber]` wants the uppercase hex form of the
  /// certificate serial (no `0x`, no colons), matching what the certificates
  /// API returns in `attributes.serialNumber`.
  static String serialNumberFromCertificatePem(String pem) {
    final tbs = X509Utils.x509CertificateFromPem(pem).tbsCertificate;
    if (tbs == null) {
      throw AppleError('Certificate PEM is missing a TBS certificate');
    }
    final hex = tbs.serialNumber.toRadixString(16).toUpperCase();
    return hex.length.isOdd ? '0$hex' : hex;
  }
}

class _SigningIdentity {
  const _SigningIdentity({required this.serialNumber});

  final String serialNumber;
}
