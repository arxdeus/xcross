import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/signing/signing_asset.dart';
import 'package:xcross/src/util/errors.dart';

void main() {
  final now = DateTime.utc(2030, 1, 2, 3, 4, 5);
  late Directory temporaryDirectory;
  late RSAPrivateKey privateKey;
  late RSAPublicKey publicKey;
  late String privateKeyPem;
  late String certificatePem;
  late Uint8List certificateDer;
  late String otherPrivateKeyPem;
  late Uint8List otherCertificateDer;

  setUpAll(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'xcross_signing_asset-',
    );
    final primary = _certificateFixture('xcross Test Developer');
    privateKey = primary.privateKey;
    publicKey = primary.publicKey;
    privateKeyPem = primary.privateKeyPem;
    certificatePem = primary.certificatePem;
    certificateDer = primary.certificateDer;

    final other = _certificateFixture('Other Test Developer');
    otherPrivateKeyPem = other.privateKeyPem;
    otherCertificateDer = other.certificateDer;
  });

  tearDownAll(() => temporaryDirectory.delete(recursive: true));

  test('loads XML profile signing assets', () async {
    final paths = await _writeFixture(
      temporaryDirectory,
      'xml',
      privateKeyPem: privateKeyPem,
      certificatePem: certificatePem,
      developerCertificates: [certificateDer],
    );

    final asset = await SigningAsset.load(
      privateKeyPemPath: paths.key,
      certificatePemPath: paths.certificate,
      provisioningProfilePath: paths.profile,
      now: now,
      trustedRootCertificates: [certificateDer],
    );

    expect(asset.privateKey.modulus, privateKey.modulus);
    expect(asset.leafCertificateDer, orderedEquals(certificateDer));
    expect(
      asset.profileCmsBytes,
      orderedEquals(File(paths.profile).readAsBytesSync()),
    );
    expect(asset.profilePlistBytes, isNotEmpty);
    expect(asset.profile['Name'], 'xcross Test Profile');
    expect(asset.entitlements['get-task-allow'], isTrue);
    expect(asset.teamIdentifier, 'TESTTEAM123');
    expect(asset.applicationIdentifier, 'TESTTEAM123.dev.xcross.test');
    expect(asset.applicationIdentifierPrefix, 'TESTPREFIX');
    expect(asset.certificateCommonName, 'xcross Test Developer');
  });

  test('loads a binary profile plist', () async {
    final paths = await _writeFixture(
      temporaryDirectory,
      'binary',
      privateKeyPem: privateKeyPem,
      certificatePem: certificatePem,
      developerCertificates: [certificateDer],
      binaryPlist: true,
    );

    final asset = await SigningAsset.load(
      privateKeyPemPath: paths.key,
      certificatePemPath: paths.certificate,
      provisioningProfilePath: paths.profile,
      now: now,
      trustedRootCertificates: [certificateDer],
    );

    expect(asset.profile['Name'], 'xcross Test Profile');
    expect(asset.teamIdentifier, 'TESTTEAM123');
  });

  test(
    'builds deterministic detached CMS with verifiable signed attributes',
    () async {
      final paths = await _writeFixture(
        temporaryDirectory,
        'cms-output',
        privateKeyPem: privateKeyPem,
        certificatePem: certificatePem,
        developerCertificates: [certificateDer],
        embeddedCertificates: [certificateDer, otherCertificateDer],
      );
      final asset = await SigningAsset.load(
        privateKeyPemPath: paths.key,
        certificatePemPath: paths.certificate,
        provisioningProfilePath: paths.profile,
        now: now,
        trustedRootCertificates: [certificateDer],
      );
      final codeDirectory = Uint8List.fromList(
        utf8.encode('deterministic CodeDirectory bytes'),
      );
      final cdhash = Uint8List.fromList(sha256.convert(codeDirectory).bytes);
      final signingTime = DateTime.utc(2030, 2, 3, 4, 5, 6);

      final cms = asset.buildDetachedCms(
        codeDirectoryBytes: codeDirectory,
        cdhashBytes: cdhash,
        signingTime: signingTime,
      );
      final secondCms = asset.buildDetachedCms(
        codeDirectoryBytes: codeDirectory,
        cdhashBytes: cdhash,
        signingTime: signingTime,
      );
      expect(secondCms, orderedEquals(cms));

      final contentInfo = _single(cms, 0x30).children();
      expect(_oidValue(contentInfo[0]), _oidSignedData);
      final signedData = _single(contentInfo[1].value, 0x30).children();
      final digestAlgorithm = signedData[1].children().single.children();
      expect(digestAlgorithm, hasLength(1));
      expect(_oidValue(digestAlgorithm.single), _oidSha256);
      final encapsulated = signedData[2].children();
      expect(_oidValue(encapsulated.single), _oidData);

      final embeddedCertificates = signedData[3]
          .children()
          .map((value) => base64.encode(value.encoded))
          .toList();
      expect(embeddedCertificates, [base64.encode(certificateDer)]);

      final signerInfo = signedData[4].children().single.children();
      final signerDigestAlgorithm = signerInfo[2].children();
      expect(signerDigestAlgorithm, hasLength(1));
      expect(_oidValue(signerDigestAlgorithm.single), _oidSha256);
      final implicitAttributes = signerInfo[3];
      expect(implicitAttributes.tag, 0xa0);
      final attributes = _TestReader(implicitAttributes.value).all();
      final encodedAttributes = attributes
          .map((attribute) => base64.encode(attribute.encoded))
          .toList();
      final sortedAttributes = attributes.map((value) => value.encoded).toList()
        ..sort(_compareBytes);
      expect(
        encodedAttributes,
        orderedEquals(sortedAttributes.map(base64.encode)),
      );

      final valuesByOid = <String, _TestValue>{};
      for (final attribute in attributes) {
        final parts = attribute.children();
        valuesByOid[_oidValue(parts[0])] = parts[1].children().single;
      }
      expect(
        valuesByOid[_oidMessageDigest]!.value,
        orderedEquals(sha256.convert(codeDirectory).bytes),
      );
      expect(valuesByOid[_oidContentType]!.tag, 0x06);
      expect(_oidValue(valuesByOid[_oidContentType]!), _oidData);
      expect(valuesByOid[_oidSigningTime]!.tag, 0x17);

      final cdhashPlist =
          PropertyListSerialization.propertyListWithString(
                utf8.decode(valuesByOid[_oidAppleCdHashes]!.value),
              )
              as Map<Object?, Object?>;
      final plistHash =
          (cdhashPlist['cdhashes']! as List<Object?>).single! as ByteData;
      expect(
        plistHash.buffer.asUint8List(
          plistHash.offsetInBytes,
          plistHash.lengthInBytes,
        ),
        orderedEquals(cdhash.sublist(0, 20)),
      );
      final cdHashes2 = valuesByOid[_oidAppleCdHashes2]!.children();
      expect(_oidValue(cdHashes2[0]), _oidSha256);
      expect(cdHashes2[1].value, orderedEquals(cdhash));

      final signedAttributes = _tlv(0x31, implicitAttributes.value);
      final verifier = Signer('SHA-256/RSA')
        ..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
      expect(
        verifier.verifySignature(
          signedAttributes,
          RSASignature(Uint8List.fromList(signerInfo[5].value)),
        ),
        isTrue,
      );
    },
  );

  test('embeds only the ordered developer certificate chain', () async {
    final root = _certificateFixture('Synthetic Root CA');
    final intermediate = _certificateFixture(
      'Synthetic Intermediate CA',
      issuerCertificateDer: root.certificateDer,
    );
    final leaf = _certificateFixture(
      'Synthetic Developer',
      issuerCertificateDer: intermediate.certificateDer,
    );
    final unrelated = _certificateFixture('Unrelated Profile CA');
    final paths = await _writeFixture(
      temporaryDirectory,
      'certificate-chain',
      privateKeyPem: leaf.privateKeyPem,
      certificatePem: leaf.certificatePem,
      developerCertificates: [leaf.certificateDer],
      embeddedCertificates: [
        unrelated.certificateDer,
        root.certificateDer,
        intermediate.certificateDer,
      ],
    );

    final asset = await SigningAsset.load(
      privateKeyPemPath: paths.key,
      certificatePemPath: paths.certificate,
      provisioningProfilePath: paths.profile,
      now: now,
      trustedRootCertificates: [root.certificateDer],
    );
    final codeDirectory = Uint8List.fromList([1, 2, 3]);
    final cms = asset.buildDetachedCms(
      codeDirectoryBytes: codeDirectory,
      cdhashBytes: Uint8List.fromList(sha256.convert(codeDirectory).bytes),
      signingTime: now,
    );
    final contentInfo = _single(cms, 0x30).children();
    final signedData = _single(contentInfo[1].value, 0x30).children();
    final certificates = signedData[3]
        .children()
        .map((value) => base64.encode(value.encoded))
        .toList();

    expect(
      certificates,
      unorderedEquals([
        base64.encode(leaf.certificateDer),
        base64.encode(intermediate.certificateDer),
        base64.encode(root.certificateDer),
      ]),
    );
    expect(
      certificates,
      isNot(contains(base64.encode(unrelated.certificateDer))),
    );
  });

  test('rejects an unknown developer certificate issuer', () async {
    final intermediate = _certificateFixture('Unknown Intermediate CA');
    final leaf = _certificateFixture(
      'Unknown Issuer Developer',
      issuerCertificateDer: intermediate.certificateDer,
    );
    final unrelated = _certificateFixture('Unknown Unrelated CA');
    final paths = await _writeFixture(
      temporaryDirectory,
      'unknown-certificate-issuer',
      privateKeyPem: leaf.privateKeyPem,
      certificatePem: leaf.certificatePem,
      developerCertificates: [leaf.certificateDer],
      embeddedCertificates: [unrelated.certificateDer],
    );

    await expectLater(
      SigningAsset.load(
        privateKeyPemPath: paths.key,
        certificatePemPath: paths.certificate,
        provisioningProfilePath: paths.profile,
        now: now,
      ),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          contains('Unknown Intermediate CA'),
        ),
      ),
    );
  });

  test('rejects a matching chain anchored to an unknown root', () async {
    final fakeRoot = _certificateFixture('Fake Root CA');
    final leaf = _certificateFixture(
      'Fake Root Developer',
      issuerCertificateDer: fakeRoot.certificateDer,
    );
    final paths = await _writeFixture(
      temporaryDirectory,
      'unknown-certificate-root',
      privateKeyPem: leaf.privateKeyPem,
      certificatePem: leaf.certificatePem,
      developerCertificates: [leaf.certificateDer],
      embeddedCertificates: [fakeRoot.certificateDer],
    );

    await expectLater(
      SigningAsset.load(
        privateKeyPemPath: paths.key,
        certificatePemPath: paths.certificate,
        provisioningProfilePath: paths.profile,
        now: now,
      ),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          contains('not anchored to an Apple root'),
        ),
      ),
    );
  });

  test('rejects a key that does not match the leaf certificate', () async {
    final paths = await _writeFixture(
      temporaryDirectory,
      'key-mismatch',
      privateKeyPem: otherPrivateKeyPem,
      certificatePem: certificatePem,
      developerCertificates: [certificateDer],
    );

    await expectLater(
      SigningAsset.load(
        privateKeyPemPath: paths.key,
        certificatePemPath: paths.certificate,
        provisioningProfilePath: paths.profile,
        now: now,
      ),
      throwsA(
        isA<XcrossError>()
            .having((error) => error.message, 'message', contains(paths.key))
            .having(
              (error) => error.message,
              'message',
              contains('does not match'),
            ),
      ),
    );
  });

  test('rejects an expired provisioning profile', () async {
    final paths = await _writeFixture(
      temporaryDirectory,
      'expired-profile',
      privateKeyPem: privateKeyPem,
      certificatePem: certificatePem,
      developerCertificates: [certificateDer],
      creationDate: DateTime.utc(2020),
      expirationDate: DateTime.utc(2021),
    );

    await expectLater(
      SigningAsset.load(
        privateKeyPemPath: paths.key,
        certificatePemPath: paths.certificate,
        provisioningProfilePath: paths.profile,
        now: now,
      ),
      throwsA(
        isA<XcrossError>()
            .having(
              (error) => error.message,
              'message',
              contains(paths.profile),
            )
            .having((error) => error.message, 'message', contains('expired')),
      ),
    );
  });

  test('rejects a certificate absent from DeveloperCertificates', () async {
    final paths = await _writeFixture(
      temporaryDirectory,
      'certificate-absent',
      privateKeyPem: privateKeyPem,
      certificatePem: certificatePem,
      developerCertificates: [otherCertificateDer],
    );

    await expectLater(
      SigningAsset.load(
        privateKeyPemPath: paths.key,
        certificatePemPath: paths.certificate,
        provisioningProfilePath: paths.profile,
        now: now,
      ),
      throwsA(
        isA<XcrossError>()
            .having(
              (error) => error.message,
              'message',
              contains(paths.profile),
            )
            .having((error) => error.message, 'message', contains('absent')),
      ),
    );
  });

  test('rejects malformed mobileprovision CMS with path context', () async {
    final paths = await _writeFixture(
      temporaryDirectory,
      'malformed-cms',
      privateKeyPem: privateKeyPem,
      certificatePem: certificatePem,
      developerCertificates: [certificateDer],
      profileCmsOverride: Uint8List.fromList([0x30, 0x82, 0xff]),
    );

    await expectLater(
      SigningAsset.load(
        privateKeyPemPath: paths.key,
        certificatePemPath: paths.certificate,
        provisioningProfilePath: paths.profile,
        now: now,
      ),
      throwsA(
        isA<XcrossError>()
            .having(
              (error) => error.message,
              'message',
              contains(paths.profile),
            )
            .having((error) => error.message, 'message', contains('Malformed')),
      ),
    );
  });
}

({
  RSAPrivateKey privateKey,
  RSAPublicKey publicKey,
  String privateKeyPem,
  String certificatePem,
  Uint8List certificateDer,
})
_certificateFixture(String commonName, {Uint8List? issuerCertificateDer}) {
  final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 1024);
  final privateKey = keyPair.privateKey as RSAPrivateKey;
  final publicKey = keyPair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem(
    {'CN': commonName},
    privateKey,
    publicKey,
  );
  final selfSignedPem = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csr,
    7300,
    notBefore: DateTime.utc(2029),
  );
  var certificateDer = CryptoUtils.getBytesFromPEMString(selfSignedPem);
  if (issuerCertificateDer != null) {
    certificateDer = _replaceCertificateIssuer(
      certificateDer,
      _certificateSubject(issuerCertificateDer),
    );
  }
  final certificatePem =
      '-----BEGIN CERTIFICATE-----\n${base64.encode(certificateDer)}\n'
      '-----END CERTIFICATE-----';
  return (
    privateKey: privateKey,
    publicKey: publicKey,
    privateKeyPem: CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
    certificatePem: certificatePem,
    certificateDer: certificateDer,
  );
}

Uint8List _certificateSubject(Uint8List der) {
  final tbs = _single(der, 0x30).children().first.children();
  final firstField = tbs.first.tag == 0xa0 ? 1 : 0;
  return Uint8List.fromList(tbs[firstField + 4].encoded);
}

Uint8List _replaceCertificateIssuer(Uint8List der, Uint8List issuer) {
  final certificate = _single(der, 0x30).children();
  final tbs = certificate.first.children();
  final firstField = tbs.first.tag == 0xa0 ? 1 : 0;
  return _sequence([
    _sequence([
      for (var index = 0; index < tbs.length; index++)
        index == firstField + 2 ? issuer : tbs[index].encoded,
    ]),
    ...certificate.skip(1).map((value) => value.encoded),
  ]);
}

Future<({String key, String certificate, String profile})> _writeFixture(
  Directory root,
  String name, {
  required String privateKeyPem,
  required String certificatePem,
  required List<Uint8List> developerCertificates,
  List<Uint8List>? embeddedCertificates,
  DateTime? creationDate,
  DateTime? expirationDate,
  bool binaryPlist = false,
  Uint8List? profileCmsOverride,
}) async {
  final directory = Directory('${root.path}/$name')..createSync();
  final keyPath = '${directory.path}/key.pem';
  final certificatePath = '${directory.path}/certificate.pem';
  final profilePath = '${directory.path}/profile.mobileprovision';
  await File(keyPath).writeAsString(privateKeyPem);
  await File(certificatePath).writeAsString(certificatePem);

  final profile = <String, Object>{
    'Name': 'xcross Test Profile',
    'CreationDate': creationDate ?? DateTime.utc(2029),
    'ExpirationDate': expirationDate ?? DateTime.utc(2040),
    'TeamIdentifier': ['TESTTEAM123'],
    'ApplicationIdentifierPrefix': ['TESTPREFIX'],
    'Entitlements': <String, Object>{
      'application-identifier': 'TESTTEAM123.dev.xcross.test',
      'get-task-allow': true,
    },
    'DeveloperCertificates': [
      for (final certificate in developerCertificates)
        ByteData.sublistView(certificate),
    ],
  };
  final Uint8List plist;
  if (binaryPlist) {
    final data = PropertyListSerialization.dataWithPropertyList(profile);
    plist = Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } else {
    plist = Uint8List.fromList(
      utf8.encode(PropertyListSerialization.stringWithPropertyList(profile)),
    );
  }
  await File(profilePath).writeAsBytes(
    profileCmsOverride ??
        _profileCms(plist, embeddedCertificates ?? developerCertificates),
  );
  return (key: keyPath, certificate: certificatePath, profile: profilePath);
}

Uint8List _profileCms(Uint8List plist, List<Uint8List> certificates) =>
    _sequence([
      _oid(_oidSignedData),
      _tlv(
        0xa0,
        _sequence([
          _integer(1),
          _set([_algorithmIdentifier(_oidSha256)]),
          _sequence([_oid(_oidData), _tlv(0xa0, _octet(plist))]),
          _tlv(0xa0, _sortedContent(certificates)),
          _set(const []),
        ]),
      ),
    ]);

const _oidData = '1.2.840.113549.1.7.1';
const _oidSignedData = '1.2.840.113549.1.7.2';
const _oidContentType = '1.2.840.113549.1.9.3';
const _oidMessageDigest = '1.2.840.113549.1.9.4';
const _oidSigningTime = '1.2.840.113549.1.9.5';
const _oidSha256 = '2.16.840.1.101.3.4.2.1';
const _oidAppleCdHashes = '1.2.840.113635.100.9.1';
const _oidAppleCdHashes2 = '1.2.840.113635.100.9.2';

Uint8List _algorithmIdentifier(String oid) =>
    _sequence([_oid(oid), _tlv(0x05, const [])]);

Uint8List _sequence(Iterable<Uint8List> values) => _tlv(0x30, _concat(values));

Uint8List _set(Iterable<Uint8List> values) =>
    _tlv(0x31, _sortedContent(values));

Uint8List _octet(List<int> value) => _tlv(0x04, value);

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
  final bytes = value.toList();
  final length = <int>[];
  var remaining = bytes.length;
  do {
    length.insert(0, remaining & 0xff);
    remaining >>= 8;
  } while (remaining != 0);
  return Uint8List.fromList([
    tag,
    if (bytes.length < 128) bytes.length else 0x80 | length.length,
    if (bytes.length >= 128) ...length,
    ...bytes,
  ]);
}

Uint8List _concat(Iterable<Uint8List> values) =>
    Uint8List.fromList([for (final value in values) ...value]);

Uint8List _sortedContent(Iterable<Uint8List> values) {
  final sorted = values.map(Uint8List.fromList).toList()..sort(_compareBytes);
  return _concat(sorted);
}

int _compareBytes(List<int> left, List<int> right) {
  final length = left.length < right.length ? left.length : right.length;
  for (var index = 0; index < length; index++) {
    final comparison = left[index].compareTo(right[index]);
    if (comparison != 0) return comparison;
  }
  return left.length.compareTo(right.length);
}

_TestValue _single(Uint8List bytes, int tag) {
  final reader = _TestReader(bytes);
  final value = reader.read();
  expect(value.tag, tag);
  expect(reader.isDone, isTrue);
  return value;
}

String _oidValue(_TestValue oid) {
  final values = <int>[];
  var current = 0;
  for (final byte in oid.value) {
    current = current * 128 + (byte & 0x7f);
    if (byte & 0x80 == 0) {
      values.add(current);
      current = 0;
    }
  }
  final first = values.removeAt(0);
  final firstArc = first < 40
      ? 0
      : first < 80
      ? 1
      : 2;
  return [firstArc, first - firstArc * 40, ...values].join('.');
}

class _TestReader {
  _TestReader(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;

  bool get isDone => _offset == _bytes.length;

  _TestValue read() {
    final start = _offset;
    final tag = _bytes[_offset++];
    final firstLength = _bytes[_offset++];
    var length = firstLength;
    if (firstLength & 0x80 != 0) {
      final count = firstLength & 0x7f;
      length = 0;
      for (var index = 0; index < count; index++) {
        length = length * 256 + _bytes[_offset++];
      }
    }
    final valueStart = _offset;
    _offset += length;
    return _TestValue(
      tag,
      Uint8List.sublistView(_bytes, start, _offset),
      Uint8List.sublistView(_bytes, valueStart, _offset),
    );
  }

  List<_TestValue> all() {
    final values = <_TestValue>[];
    while (!isDone) {
      values.add(read());
    }
    return values;
  }
}

class _TestValue {
  const _TestValue(this.tag, this.encoded, this.value);

  final int tag;
  final Uint8List encoded;
  final Uint8List value;

  List<_TestValue> children() => _TestReader(value).all();
}
