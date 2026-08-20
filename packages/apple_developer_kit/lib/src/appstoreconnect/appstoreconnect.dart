/// App Store Connect API client for provisioning iOS Development signing
/// (certificates, devices, bundle ids, profiles) using only a Team-scoped
/// API key - no interactive Apple ID / GrandSlam login.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:apple_developer_kit/src/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_csr.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_models.dart';
import 'package:apple_developer_kit/src/appstoreconnect/provisioning_identifiers.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Where [AscProvisioning.provisionDevelopmentIdentity] left the three files
/// a signer needs.
@immutable
final class DevelopmentIdentityPaths {
  const DevelopmentIdentityPaths({
    required this.certificatePemPath,
    required this.privateKeyPemPath,
    required this.profilePath,
  });

  final String certificatePemPath;
  final String privateKeyPemPath;
  final String profilePath;
}

/// Progress notes for actions the user should know about, such as revoking a
/// certificate whose private key is gone.
typedef ProvisioningProgress = void Function(String message);

/// Development identity provisioning against App Store Connect.
abstract final class AscProvisioning {
  /// Wraps [derBase64] (base64-encoded DER, as returned raw by the
  /// certificates API's `certificateContent`) into a line-wrapped PEM block.
  ///
  /// The API does NOT return PEM directly - dumping `certificateContent` to a
  /// `.pem` file as-is produces an invalid certificate.
  @useResult
  static String wrapDerAsPem(String derBase64, {String label = 'CERTIFICATE'}) {
    // Re-encoding normalises whatever line breaks Apple sent.
    final body = base64.encode(base64.decode(derBase64));
    final pem = StringBuffer('-----BEGIN $label-----\n');
    for (var i = 0; i < body.length; i += 64) {
      pem.writeln(body.substring(i, min(i + 64, body.length)));
    }
    pem.write('-----END $label-----\n');
    return pem.toString();
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
  static Future<DevelopmentIdentityPaths> provisionDevelopmentIdentity({
    required DevelopmentProvisioningClient client,
    required String bundleId,
    required List<String> deviceUdids,
    required String outputDir,
    String? identityDir,
    List<String> appGroups = const [],
    ProvisioningProgress? onProgress,
  }) async {
    final signingIdentityDir = identityDir ?? outputDir;
    await Future.wait([
      Directory(outputDir).create(recursive: true),
      Directory(signingIdentityDir).create(recursive: true),
    ]);

    final certPath = p.join(signingIdentityDir, 'cert.pem');
    final keyPath = p.join(signingIdentityDir, 'key.pem');
    final profilePath = p.join(outputDir, 'profile.mobileprovision');

    final serialNumber = await _loadOrIssueIdentity(
      client: client,
      certPath: certPath,
      keyPath: keyPath,
      statePath: p.join(signingIdentityDir, 'state.json'),
      onProgress: onProgress,
    );

    final bundleIdResource = await _findOrRegisterBundleId(client, bundleId);
    await _assignAppGroups(
      client,
      bundleIdResource: bundleIdResource,
      appGroups: appGroups,
      onProgress: onProgress,
    );
    for (final udid in deviceUdids) {
      await client.findDeviceByUdid(udid) ??
          await client.registerDevice(udid: udid, name: udid);
    }
    await _freeProfileSlot(client, bundleIdResource.id);

    final certificateIds = await _teamCertificateIds(client, serialNumber);
    final deviceIds = await _profileDeviceIds(client, deviceUdids);
    final profile = await client.createProfile(
      name: 'xcross Development ${DateTime.now().microsecondsSinceEpoch}',
      bundleIdResourceId: bundleIdResource.id,
      certificateResourceIds: certificateIds,
      deviceResourceIds: deviceIds,
    );
    await File(
      profilePath,
    ).writeAsBytes(base64.decode(profile.profileContentBase64));

    return DevelopmentIdentityPaths(
      certificatePemPath: certPath,
      privateKeyPemPath: keyPath,
      profilePath: profilePath,
    );
  }

  static Future<AscBundleId> _findOrRegisterBundleId(
    DevelopmentProvisioningClient client,
    String bundleId,
  ) async =>
      await client.findBundleId(bundleId) ??
      await client.registerBundleId(
        identifier: bundleId,
        name: ProvisioningIdentifiers.appName(bundleId),
      );

  /// Registers any missing App Groups and enables the App Groups capability
  /// on the bundle id, so the issued profile's entitlements actually carry
  /// `com.apple.security.application-groups`.
  ///
  /// Without this an app and its share extension are each sandboxed into
  /// their own container and cannot exchange the shared files/data an
  /// extension exists to hand over.
  static Future<void> _assignAppGroups(
    DevelopmentProvisioningClient client, {
    required AscBundleId bundleIdResource,
    required List<String> appGroups,
    ProvisioningProgress? onProgress,
  }) async {
    if (appGroups.isEmpty) return;

    try {
      final resourceIds = <String>[];
      for (final identifier in appGroups) {
        final existing = await client.findAppGroup(identifier);
        if (existing != null) {
          resourceIds.add(existing.id);
          continue;
        }
        final created = await client.registerAppGroup(
          identifier: identifier,
          name: ProvisioningIdentifiers.appName(identifier),
        );
        resourceIds.add(created.id);
      }

      await client.assignAppGroups(
        bundleIdResourceId: bundleIdResource.id,
        appGroupResourceIds: resourceIds,
      );
    } on Object catch (error) {
      // Never fatal: the app, its extensions and their profiles are all
      // valid without a shared container. Only the data hand-off between an
      // extension and its host app is missing, so an App Groups problem must
      // not cost the user their build.
      //
      // Both backends reach App Groups over the same legacy protocol now, so
      // a failure here is a real error (an expired session, a revoked key, a
      // team that cannot register more identifiers) rather than the API
      // simply not supporting it.
      final unauthorized =
          error is AppleApiError &&
          (error.statusCode == 401 || error.statusCode == 403);
      onProgress?.call(
        unauthorized
            ? 'App Groups (${appGroups.join(', ')}) could not be enabled: '
                  'Apple rejected the credentials for the legacy provisioning '
                  'endpoint ($error). The app and its extensions still '
                  'install, but they cannot share data until this is fixed.'
            : 'Could not enable App Groups (${appGroups.join(', ')}) on '
                  '${bundleIdResource.identifier}: $error',
      );
    }
  }

  /// xtool: if the bundle already has exactly one profile, delete it before
  /// creating a fresh one (free teams are limited; paid teams with >1 are
  /// left alone).
  static Future<void> _freeProfileSlot(
    DevelopmentProvisioningClient client,
    String bundleIdResourceId,
  ) async {
    final existing = await client.listProfileIdsForBundle(bundleIdResourceId);
    if (existing.length == 1) await client.deleteProfile(existing.single);
  }

  static Future<List<String>> _teamCertificateIds(
    DevelopmentProvisioningClient client,
    String serialNumber,
  ) async {
    final ids = await client.findCertificateIdsBySerial(serialNumber);
    if (ids.isEmpty) {
      throw AppleError(
        'Development certificate serial $serialNumber is not on '
        'the team after issuance. Run xcross auth again, or revoke stale '
        'certificates at developer.apple.com.',
      );
    }
    return ids;
  }

  /// xtool attaches every iPhone/iPad/iPod on the team, not just the current
  /// UDID — Apple's profile create is picky about device membership.
  static Future<List<String>> _profileDeviceIds(
    DevelopmentProvisioningClient client,
    List<String> deviceUdids,
  ) async {
    final ids = {
      for (final device in await client.listDevices())
        if (device.supportsIosApps || deviceUdids.contains(device.udid))
          device.id,
    }.toList();
    if (ids.isEmpty) {
      throw const AppleError(
        'No iOS devices are registered on this team. Plug in a device and '
        'retry.',
      );
    }
    return ids;
  }

  /// xtool `DeveloperServicesFetchCertificateOperation.perform`: reuse the
  /// local identity when its serial is still on the team and unexpired;
  /// otherwise revoke team certificates and create a new one. Returns the
  /// certificate's serial number.
  static Future<String> _loadOrIssueIdentity({
    required DevelopmentProvisioningClient client,
    required String certPath,
    required String keyPath,
    required String statePath,
    ProvisioningProgress? onProgress,
  }) async {
    final cached = await _cachedSerialNumber(statePath, certPath, keyPath);
    if (cached != null) {
      if ((await client.findCertificateIdsBySerial(cached)).isNotEmpty) {
        return cached;
      }
      onProgress?.call(
        'Cached Development certificate serial $cached is '
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

  static Future<String> _issueAndPersistIdentity({
    required DevelopmentProvisioningClient client,
    required String certPath,
    required String keyPath,
    required String statePath,
    ProvisioningProgress? onProgress,
  }) async {
    final csr = AscCsr.generate();
    final certificate = await _issueDevelopmentCertificate(
      client,
      csr.csrPem,
      onProgress: onProgress,
    );
    await File(
      certPath,
    ).writeAsString(wrapDerAsPem(certificate.certificateContentBase64));
    await AscCsr.writePrivateKeyPem(
      keyPath,
      AscCsr.privateKeyToPem(csr.privateKey),
    );
    final serialNumber =
        certificate.serialNumber ??
        _serialNumberFromCertificatePem(await File(certPath).readAsString());
    await File(statePath).writeAsString(
      jsonEncode({
        'certificateId': certificate.id,
        'certificateSerialNumber': serialNumber,
        'certificateExpirationDate': certificate.expirationDate,
      }),
    );
    return serialNumber;
  }

  /// Issues a Development certificate. On HTTP 409 (quota), revoke every
  /// certificate on the team first — same as xtool's free-team
  /// `replaceCertificates`.
  static Future<AscCertificate> _issueDevelopmentCertificate(
    DevelopmentProvisioningClient client,
    String csrPem, {
    ProvisioningProgress? onProgress,
  }) async {
    try {
      return await client.createDevelopmentCertificate(csrPem: csrPem);
    } on AppleApiError catch (error) {
      if (error.statusCode != 409) rethrow;
      // A 409 with nothing to revoke means a *pending* request, which
      // revoking cannot clear; surface it rather than retrying pointlessly.
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
    ProvisioningProgress? onProgress,
  }) async {
    for (final id in knownIds ?? await client.listCertificateIds()) {
      onProgress?.call(
        'Revoking certificate $id: its private key is not on this machine. '
        'Apps still signed with it must be re-signed.',
      );
      await client.revokeCertificate(id);
    }
  }

  /// Serial of the cached identity when [certPath]/[keyPath] exist and the
  /// certificate isn't expired, else null.
  static Future<String?> _cachedSerialNumber(
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
      final expiry = DateTime.tryParse(
        state['certificateExpirationDate'] as String? ?? '',
      );
      if (expiry == null || !expiry.toUtc().isAfter(DateTime.now().toUtc())) {
        return null;
      }
      final serial =
          state['certificateSerialNumber'] as String? ??
          _serialNumberFromCertificatePem(await File(certPath).readAsString());
      return serial.isEmpty ? null : serial;
    } on Object {
      // A corrupt or unreadable cache is never fatal: re-issue instead.
      return null;
    }
  }

  /// Apple's `filter[serialNumber]` wants the uppercase hex form of the
  /// certificate serial (no `0x`, no colons), matching what the certificates
  /// API returns in `attributes.serialNumber`.
  static String _serialNumberFromCertificatePem(String pem) {
    final tbs = X509Utils.x509CertificateFromPem(pem).tbsCertificate;
    if (tbs == null) {
      throw const AppleError('Certificate PEM is missing a TBS certificate');
    }
    final hex = tbs.serialNumber.toRadixString(16).toUpperCase();
    return hex.length.isOdd ? '0$hex' : hex;
  }
}
