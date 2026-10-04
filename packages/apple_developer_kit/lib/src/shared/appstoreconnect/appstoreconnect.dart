/// App Store Connect API client for provisioning iOS Development signing
/// (certificates, devices, bundle ids, profiles) using only a Team-scoped
/// API key - no interactive Apple ID / GrandSlam login.
library;

import 'dart:convert';
import 'dart:math';

import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/src/shared/appstoreconnect/asc_csr.dart';
import 'package:apple_developer_kit/src/shared/appstoreconnect/asc_models.dart';
import 'package:apple_developer_kit/src/shared/appstoreconnect/provisioning_identifiers.dart';
import 'package:apple_developer_kit/src/shared/errors/errors.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:meta/meta.dart';

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
final class AscProvisioning {
  AscProvisioning({required this.hostServices, required this.client});

  final AppleHostServices hostServices;
  final DevelopmentProvisioningClient client;

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
  /// 3. Free a development-profile slot, but only of a profile xcross itself
  ///    created - see [_freeProfileSlot]. Capabilities the app's entitlements
  ///    need are switched on before the profile is issued, because a profile
  ///    only grants what the App ID has enabled.
  /// 4. Resolve the cert's team-side id by serial (never trust create-response
  ///    id alone), attach every iOS-capable device on the team, and create an
  ///    `IOS_APP_DEVELOPMENT` profile.
  Future<DevelopmentIdentityPaths> provisionDevelopmentIdentity({
    required String bundleId,
    required List<String> deviceUdids,
    required String outputDir,
    String? identityDir,
    List<String> appGroups = const [],
    Set<String> capabilities = const {},
    ProvisioningProgress? onProgress,
  }) async {
    final signingIdentityDir = identityDir ?? outputDir;
    await Future.wait([
      hostServices.host.fileSystem.directory(outputDir).create(recursive: true),
      hostServices.host.fileSystem
          .directory(signingIdentityDir)
          .create(recursive: true),
    ]);

    final certPath = hostServices.host.paths.context.join(
      signingIdentityDir,
      'cert.pem',
    );
    final keyPath = hostServices.host.paths.context.join(
      signingIdentityDir,
      'key.pem',
    );
    final profilePath = hostServices.host.paths.context.join(
      outputDir,
      'profile.mobileprovision',
    );

    final serialNumber = await _loadOrIssueIdentity(
      certPath: certPath,
      keyPath: keyPath,
      statePath: hostServices.host.paths.context.join(
        signingIdentityDir,
        'state.json',
      ),
      onProgress: onProgress,
    );

    final bundleIdResource = await _findOrRegisterBundleId(bundleId);
    await _ensureCapabilities(
      bundleId: bundleId,
      bundleIdResource: bundleIdResource,
      capabilities: capabilities,
      onProgress: onProgress,
    );
    await _assignAppGroups(
      bundleIdResource: bundleIdResource,
      appGroups: appGroups,
      onProgress: onProgress,
    );
    for (final udid in deviceUdids) {
      await client.findDeviceByUdid(udid) ??
          await client.registerDevice(udid: udid, name: udid);
    }
    await _freeProfileSlot(bundleIdResource.id, onProgress);

    final certificateIds = await _teamCertificateIds(serialNumber);
    final deviceIds = await _profileDeviceIds(deviceUdids);
    final profile = await client.createProfile(
      name: '$profileNamePrefix${DateTime.now().microsecondsSinceEpoch}',
      bundleIdResourceId: bundleIdResource.id,
      certificateResourceIds: certificateIds,
      deviceResourceIds: deviceIds,
    );
    await hostServices.host.fileSystem
        .file(profilePath)
        .writeAsBytes(base64.decode(profile.profileContentBase64));

    return DevelopmentIdentityPaths(
      certificatePemPath: certPath,
      privateKeyPemPath: keyPath,
      profilePath: profilePath,
    );
  }

  Future<AscBundleId> _findOrRegisterBundleId(String bundleId) async =>
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
  Future<void> _assignAppGroups({
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
    } on AppGroupsUnsupported {
      // Not a failure to retry: this credential type simply cannot attach a
      // group. Stay quiet here — the caller inspects the issued profile and
      // reports what was actually granted, which is the fact that matters and
      // covers the case where a group was attached by other means.
    } on Object catch (error) {
      // Never fatal: the app, its extensions and their profiles are all valid
      // without a shared container. Only the data hand-off between an
      // extension and its host app is missing, so an App Groups problem must
      // not cost the user their build.
      final unauthorized =
          error is AppleApiError &&
          (error.statusCode == 401 || error.statusCode == 403);
      onProgress?.call(
        unauthorized
            ? 'App Groups (${appGroups.join(', ')}) could not be enabled: '
                  'Apple rejected these credentials for the legacy '
                  'provisioning endpoint ($error). The app and its extensions '
                  'still install, but they cannot share data until this is '
                  'fixed.'
            : 'Could not enable App Groups (${appGroups.join(', ')}) on '
                  '${bundleIdResource.identifier}: $error',
      );
    }
  }

  /// Prefix every profile xcross creates is named with, which is how its own
  /// are told apart from a release profile another tool made for the same App
  /// ID. Minted as `xcross Development <microseconds>`.
  static const profileNamePrefix = 'xcross Development ';

  /// Frees a development-profile slot, but only of a profile xcross made.
  ///
  /// The rule used to be xtool's "delete the bundle's profile if it has exactly
  /// one" (free teams are limited to one), which also matched a profile somebody
  /// else's tooling created: against an App ID that ships - and this branch now
  /// keeps the real bundle id when the team owns it - that one profile is the
  /// App Store one, and deleting it takes the team's release pipeline down with
  /// it.
  Future<void> _freeProfileSlot(
    String bundleIdResourceId,
    ProvisioningProgress? onProgress,
  ) async {
    final existing = await client.listProfilesForBundle(bundleIdResourceId);
    if (existing.length != 1) return;
    final only = existing.single;
    if (only.name.startsWith(profileNamePrefix)) {
      await client.deleteProfile(only.id);
      return;
    }
    if (only.isDevelopment) {
      onProgress?.call(
        'Replacing the development profile "${only.name}" - it occupies the '
        'only profile slot for this App ID.',
      );
      await client.deleteProfile(only.id);
      return;
    }
    onProgress?.call(
      'Leaving the existing profile "${only.name}" alone - xcross did not '
      'create it and it is not a development profile.',
    );
  }

  /// Switches on the capabilities an app's entitlements need, so the profile
  /// Apple issues actually grants them.
  ///
  /// Additive and idempotent: an App ID that already has them - a shipping one
  /// usually does - costs a single lookup.
  Future<void> _ensureCapabilities({
    required String bundleId,
    required AscBundleId bundleIdResource,
    required Set<String> capabilities,
    ProvisioningProgress? onProgress,
  }) async {
    if (capabilities.isEmpty) return;
    final Set<String> enabled;
    try {
      enabled = await client.listEnabledCapabilities(bundleIdResource.id);
    } on CapabilitiesUnsupported {
      onProgress?.call(
        'This backend cannot switch App ID capabilities on, so any the app '
        'declares (Sign in with Apple, Associated Domains, push) will be '
        'missing from its profile. Use an App Store Connect API key for those.',
      );
      return;
    }
    for (final type in capabilities.toList()..sort()) {
      if (enabled.contains(type)) continue;
      await client.enableCapability(
        bundleIdResourceId: bundleIdResource.id,
        capabilityType: type,
      );
      onProgress?.call('Enabled the $type capability on $bundleId');
    }
  }

  Future<List<String>> _teamCertificateIds(String serialNumber) async {
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
  Future<List<String>> _profileDeviceIds(List<String> deviceUdids) async {
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
  Future<String> _loadOrIssueIdentity({
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
      await _revokeAllCertificates(onProgress: onProgress);
    }
    return _issueAndPersistIdentity(
      certPath: certPath,
      keyPath: keyPath,
      statePath: statePath,
      onProgress: onProgress,
    );
  }

  Future<String> _issueAndPersistIdentity({
    required String certPath,
    required String keyPath,
    required String statePath,
    ProvisioningProgress? onProgress,
  }) async {
    final csr = AscCsr.generate();
    final certificate = await _issueDevelopmentCertificate(
      csr.csrPem,
      onProgress: onProgress,
    );
    await hostServices.host.fileSystem
        .file(certPath)
        .writeAsString(wrapDerAsPem(certificate.certificateContentBase64));
    await AscCsr.writePrivateKeyPem(
      keyPath,
      AscCsr.privateKeyToPem(csr.privateKey),
      hostServices: hostServices,
    );
    final serialNumber =
        certificate.serialNumber ??
        _serialNumberFromCertificatePem(
          await hostServices.host.fileSystem.file(certPath).readAsString(),
        );
    await hostServices.host.fileSystem
        .file(statePath)
        .writeAsString(
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
  Future<AscCertificate> _issueDevelopmentCertificate(
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
      await _revokeAllCertificates(knownIds: existing, onProgress: onProgress);
      return client.createDevelopmentCertificate(csrPem: csrPem);
    }
  }

  Future<void> _revokeAllCertificates({
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
  Future<String?> _cachedSerialNumber(
    String statePath,
    String certPath,
    String keyPath,
  ) async {
    if (!hostServices.host.fileSystem.file(statePath).existsSync() ||
        !hostServices.host.fileSystem.file(certPath).existsSync() ||
        !hostServices.host.fileSystem.file(keyPath).existsSync()) {
      return null;
    }
    try {
      final state = jsonDecode(
        await hostServices.host.fileSystem.file(statePath).readAsString(),
      );
      if (state is! Map) return null;
      final expiry = DateTime.tryParse(
        state['certificateExpirationDate'] as String? ?? '',
      );
      if (expiry == null || !expiry.toUtc().isAfter(DateTime.now().toUtc())) {
        return null;
      }
      final serial =
          state['certificateSerialNumber'] as String? ??
          _serialNumberFromCertificatePem(
            await hostServices.host.fileSystem.file(certPath).readAsString(),
          );
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
