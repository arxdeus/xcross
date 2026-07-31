/// App Store Connect API client for provisioning iOS Development signing
/// (certificates, devices, bundle ids, profiles) using only a Team-scoped
/// API key - no interactive Apple ID / GrandSlam login.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/appstoreconnect/asc_client.dart';
import 'package:xcross/src/appstoreconnect/asc_csr.dart';

export 'asc_client.dart';
export 'asc_config.dart';
export 'asc_csr.dart';
export 'asc_jwt.dart';
export 'asc_models.dart';

/// Wraps [derBase64] (base64-encoded DER, as returned raw by the
/// certificates API's `certificateContent`) into a line-wrapped PEM block.
///
/// The API does NOT return PEM directly - dumping `certificateContent` to a
/// `.pem` file as-is produces an invalid certificate.
String wrapDerAsPem(String derBase64, {String label = 'CERTIFICATE'}) {
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

/// Runs the full Development-signing provisioning flow against [client]:
/// find-or-register [bundleId] and each of [deviceUdids], issue (or reuse a
/// cached, unexpired) Development certificate, and generate a provisioning
/// profile covering all of it. Files are written under [outputDir].
///
/// A cached certificate + key are reused across calls (tracked via
/// `state.json` in [outputDir]) so this doesn't burn through Apple's
/// per-membership-year certificate quota on every run. The profile is
/// (re)created every call - profiles aren't quota-limited the same way.
Future<
  ({String certificatePemPath, String privateKeyPemPath, String profilePath})
>
provisionDevelopmentIdentity({
  required AscClient client,
  required String bundleId,
  required List<String> deviceUdids,
  required String outputDir,
}) async {
  await Directory(outputDir).create(recursive: true);

  final certPath = p.join(outputDir, 'cert.pem');
  final keyPath = p.join(outputDir, 'key.pem');
  final statePath = p.join(outputDir, 'state.json');
  final profilePath = p.join(outputDir, 'profile.mobileprovision');

  var certificateId = await _cachedCertificateId(statePath, certPath, keyPath);
  if (certificateId == null) {
    final csr = AscCsr.generate();
    final certificate = await client.createCertificate(
      certificateType: 'IOS_DEVELOPMENT',
      csrPem: csr.csrPem,
    );
    await File(
      certPath,
    ).writeAsString(wrapDerAsPem(certificate.certificateContentBase64));
    await AscCsr.writePrivateKeyPem(
      keyPath,
      AscCsr.privateKeyToPem(csr.privateKey),
    );
    certificateId = certificate.id;
    await File(statePath).writeAsString(
      jsonEncode({
        'certificateId': certificate.id,
        'certificateExpirationDate': certificate.expirationDate,
      }),
    );
  }

  final bundleIdResource =
      await client.findBundleId(bundleId) ??
      await client.registerBundleId(identifier: bundleId, name: bundleId);

  final deviceResourceIds = <String>[];
  for (final udid in deviceUdids) {
    final device =
        await client.findDeviceByUdid(udid) ??
        await client.registerDevice(udid: udid, name: udid);
    deviceResourceIds.add(device.id);
  }

  final profile = await client.createProfile(
    name: '$bundleId Development',
    bundleIdResourceId: bundleIdResource.id,
    certificateResourceIds: [certificateId],
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

/// Returns the cached certificate resource id from [statePath] if [certPath]
/// and [keyPath] both exist and the cached certificate isn't expired, else
/// null (meaning: issue a new certificate).
Future<String?> _cachedCertificateId(
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
    final id = state['certificateId'] as String?;
    if (id == null) return null;
    final expirationDate = state['certificateExpirationDate'] as String?;
    if (expirationDate != null) {
      final expiry = DateTime.tryParse(expirationDate);
      if (expiry != null && !expiry.toUtc().isAfter(DateTime.now().toUtc())) {
        return null; // expired, must reissue
      }
    }
    return id;
  } on FormatException {
    return null;
  }
}
