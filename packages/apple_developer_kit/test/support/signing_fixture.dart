import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/signing/signing_asset.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';

/// A throwaway signing identity: a self-signed certificate, its key, and a
/// development provisioning profile wrapped in a minimal CMS envelope.
///
/// Trusted only through [SigningAssetLoader.load]'s `trustedRootCertificates`,
/// so signing a real app with it exercises the full device signing path
/// without an Apple account.
@internal
Future<SigningAsset> createTestSigningAsset(
  Directory directory,
  String name,
  String applicationIdentifier, {
  required AppleHostServices hostServices,
  String teamIdentifier = 'TESTTEAM123',
}) {
  final fixture = Directory(p.join(directory.path, name))..createSync();
  final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 1024);
  final privateKey = keyPair.privateKey as RSAPrivateKey;
  final publicKey = keyPair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem(
    {'CN': 'xcross Test Developer'},
    privateKey,
    publicKey,
  );
  final certificatePem = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csr,
    7300,
    notBefore: DateTime.utc(2029),
  );
  final certificateDer = CryptoUtils.getBytesFromPEMString(certificatePem);
  final profile = <String, Object>{
    'CreationDate': DateTime.utc(2029),
    'ExpirationDate': DateTime.utc(2040),
    'TeamIdentifier': [teamIdentifier],
    'ApplicationIdentifierPrefix': [teamIdentifier],
    'Entitlements': <String, Object>{
      'application-identifier': applicationIdentifier,
      'get-task-allow': true,
    },
    'DeveloperCertificates': [ByteData.sublistView(certificateDer)],
  };
  final plist = Uint8List.fromList(
    utf8.encode(PropertyListSerialization.stringWithPropertyList(profile)),
  );
  final profileCms = _sequence([
    _oid('1.2.840.113549.1.7.2'),
    _tlv(
      0xa0,
      _sequence([
        _integer(1),
        _set([_algorithmIdentifier('2.16.840.1.101.3.4.2.1')]),
        _sequence([
          _oid('1.2.840.113549.1.7.1'),
          _tlv(0xa0, _tlv(0x04, plist)),
        ]),
        _tlv(0xa0, certificateDer),
        _set(const []),
      ]),
    ),
  ]);
  final keyPath = p.join(fixture.path, 'key.pem');
  final certificatePath = p.join(fixture.path, 'certificate.pem');
  final profilePath = p.join(fixture.path, 'profile.mobileprovision');
  File(
    keyPath,
  ).writeAsStringSync(CryptoUtils.encodeRSAPrivateKeyToPem(privateKey));
  File(certificatePath).writeAsStringSync(certificatePem);
  File(profilePath).writeAsBytesSync(profileCms);
  return SigningAssetLoader(hostServices: hostServices).load(
    privateKeyPemPath: keyPath,
    certificatePemPath: certificatePath,
    provisioningProfilePath: profilePath,
    now: DateTime.utc(2030),
    trustedRootCertificates: [certificateDer],
  );
}

Uint8List _algorithmIdentifier(String oid) =>
    _sequence([_oid(oid), _tlv(0x05, const [])]);

Uint8List _sequence(Iterable<Uint8List> values) =>
    _tlv(0x30, [for (final value in values) ...value]);

Uint8List _set(Iterable<Uint8List> values) =>
    _tlv(0x31, [for (final value in values) ...value]);

Uint8List _integer(int value) => _tlv(0x02, [value]);

Uint8List _oid(String value) {
  final arcs = value.split('.').map(int.parse).toList();
  return _tlv(0x06, [
    ..._base128(arcs[0] * 40 + arcs[1]),
    for (final arc in arcs.skip(2)) ..._base128(arc),
  ]);
}

List<int> _base128(int value) {
  final result = <int>[value & 0x7f];
  var remaining = value >> 7;
  while (remaining > 0) {
    result.insert(0, (remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  return result;
}

Uint8List _tlv(int tag, Iterable<int> value) {
  final body = value.toList();
  final length = <int>[];
  var remaining = body.length;
  do {
    length.insert(0, remaining & 0xff);
    remaining >>= 8;
  } while (remaining > 0);
  return Uint8List.fromList([
    tag,
    if (body.length < 128) body.length else 0x80 | length.length,
    if (body.length >= 128) ...length,
    ...body,
  ]);
}
