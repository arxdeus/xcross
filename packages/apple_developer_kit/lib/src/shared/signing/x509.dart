import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/src/shared/signing/der.dart';
import 'package:apple_developer_kit/src/shared/signing/internal/apple_certificates.dart';
import 'package:apple_developer_kit/src/shared/signing/internal/pem_block.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:meta/meta.dart';
import 'package:pure/pure.dart';

/// Object identifiers used by the certificate, profile, and CMS layers.
@internal
abstract final class Oid {
  static const String data = '1.2.840.113549.1.7.1';
  static const String signedData = '1.2.840.113549.1.7.2';
  static const String contentType = '1.2.840.113549.1.9.3';
  static const String messageDigest = '1.2.840.113549.1.9.4';
  static const String signingTime = '1.2.840.113549.1.9.5';
  static const String rsaEncryption = '1.2.840.113549.1.1.1';
  static const String sha256 = '2.16.840.1.101.3.4.2.1';

  /// Apple's legacy `cdhashes` signed attribute, which carries a plist of
  /// truncated 20-byte digests.
  static const String appleCdHashes = '1.2.840.113635.100.9.1';

  /// Apple's `CDHashes2` signed attribute, which carries full digests each
  /// tagged with its hash algorithm.
  static const String appleCdHashes2 = '1.2.840.113635.100.9.2';
}

/// A certificate reduced to the DER slices signing needs, plus the display
/// metadata used in error messages and chain building.
///
/// [issuer], [subject], and [serialNumber] are the original encodings, not
/// re-encodings, because CMS `SignerInfo` must reproduce the issuer and serial
/// byte for byte.
@internal
@immutable
class ParsedCertificate {
  const ParsedCertificate({
    required this.der,
    required this.issuer,
    required this.subject,
    required this.serialNumber,
    required this.publicKey,
    this.commonName = '',
    this.issuerName = '',
    this.notBefore,
    this.notAfter,
  });

  final Uint8List der;
  final Uint8List issuer;
  final Uint8List subject;
  final Uint8List serialNumber;

  /// Only populated when the certificate was parsed with `requireRsa`, which
  /// is the leaf. Chain certificates may use EC keys and leave this null.
  final RSAPublicKey? publicKey;
  final String commonName;
  final String issuerName;
  final DateTime? notBefore;
  final DateTime? notAfter;

  ParsedCertificate withMetadata({
    required String commonName,
    required String issuerName,
    required DateTime notBefore,
    required DateTime notAfter,
  }) => ParsedCertificate(
    der: der,
    issuer: issuer,
    subject: subject,
    serialNumber: serialNumber,
    publicKey: publicKey,
    commonName: commonName,
    issuerName: issuerName,
    notBefore: notBefore,
    notAfter: notAfter,
  );
}

/// Parses a PEM RSA private key in either PKCS#8 or PKCS#1 form.
///
/// The DER is walked first purely to reject non-RSA and malformed input with a
/// precise message; the key itself is then decoded from the original PEM.
@internal
@useResult
RSAPrivateKey parsePrivateKey(String pem, String path) {
  try {
    final decoded = _decodePem(pem);
    switch (decoded.label) {
      case 'PRIVATE KEY':
        final root = Der.single(
          decoded.bytes,
          DerTag.sequence,
          'PKCS#8 private key',
        );
        final reader = root.reader();
        reader.read(DerTag.integer, 'PKCS#8 version');
        final algorithm = reader.read(DerTag.sequence, 'PKCS#8 algorithm');
        final algorithmOid = Der.algorithmOid(algorithm, 'PKCS#8 algorithm');
        if (algorithmOid != Oid.rsaEncryption) {
          throw AppleError(
            'Unsupported private key algorithm in "$path"; RSA is required.',
          );
        }
        reader.read(DerTag.octetString, 'PKCS#8 private key data');
        reader.requireDone('PKCS#8 private key');
        return CryptoUtils.rsaPrivateKeyFromPem(pem);
      case 'RSA PRIVATE KEY':
        Der.single(decoded.bytes, DerTag.sequence, 'PKCS#1 private key');
        return CryptoUtils.rsaPrivateKeyFromPemPkcs1(pem);
      default:
        throw AppleError(
          'Unsupported private key algorithm in "$path"; RSA PEM is required.',
        );
    }
  } on AppleError {
    rethrow;
  } on Object catch (error) {
    throw AppleError('Malformed RSA private key "$path": $error');
  }
}

/// Parses the leaf certificate, requiring an RSA public key and a subject
/// common name (which becomes the designated requirement's subject).
@internal
@useResult
ParsedCertificate parseCertificatePem(String pem, String path) {
  try {
    final decoded = _decodePem(pem);
    if (decoded.label != 'CERTIFICATE') {
      throw const FormatException('expected a CERTIFICATE PEM block');
    }
    final parsed = _parseCertificate(decoded.bytes, path, requireRsa: true);
    final result = _withCertificateMetadata(parsed, pem);
    if (result.commonName.isEmpty) {
      throw const FormatException('certificate subject has no common name');
    }
    return result;
  } on AppleError {
    rethrow;
  } on Object catch (error) {
    throw AppleError('Malformed certificate "$path": $error');
  }
}

/// Parses a chain certificate, which may be EC rather than RSA.
@internal
@useResult
ParsedCertificate parseChainCertificate(Uint8List der, String context) {
  try {
    final parsed = _parseCertificate(der, context);
    final pem =
        '''
-----BEGIN CERTIFICATE-----
${base64.encode(der)}
-----END CERTIFICATE-----''';
    return _withCertificateMetadata(parsed, pem);
  } on Object catch (error) {
    throw AppleError('Malformed $context: $error');
  }
}

ParsedCertificate _parseCertificate(
  Uint8List der,
  String path, {
  bool requireRsa = false,
}) {
  final certificate = Der.single(der, DerTag.sequence, 'certificate');
  final certificateReader = certificate.reader();
  final tbs = certificateReader.read(DerTag.sequence, 'TBSCertificate');
  final outerSignature = certificateReader.read(
    DerTag.sequence,
    'certificate signature algorithm',
  );
  certificateReader.read(DerTag.bitString, 'certificate signature');
  certificateReader.requireDone('certificate');

  final outerSignatureOid = Der.algorithmOid(
    outerSignature,
    'certificate signature algorithm',
  );

  final tbsReader = tbs.reader();
  // The version field is an optional [0]-tagged prefix, absent in v1.
  if (tbsReader.peekTag() == DerTag.context0) {
    tbsReader.read(DerTag.context0, 'certificate version');
  }
  final serialNumber = tbsReader.read(
    DerTag.integer,
    'certificate serial number',
  );
  final tbsSignature = tbsReader.read(
    DerTag.sequence,
    'TBS signature algorithm',
  );
  final tbsSignatureOid = Der.algorithmOid(
    tbsSignature,
    'TBS signature algorithm',
  );
  // A mismatch here is the classic signature-substitution tell.
  if (tbsSignatureOid != outerSignatureOid) {
    throw const FormatException('certificate signature algorithms differ');
  }
  final issuer = tbsReader.read(DerTag.sequence, 'certificate issuer');
  tbsReader.read(DerTag.sequence, 'certificate validity');
  final subject = tbsReader.read(DerTag.sequence, 'certificate subject');
  final subjectPublicKeyInfo = tbsReader.read(
    DerTag.sequence,
    'certificate public key',
  );

  return ParsedCertificate(
    der: Uint8List.fromList(der),
    issuer: Uint8List.fromList(issuer.encoded),
    subject: Uint8List.fromList(subject.encoded),
    serialNumber: Uint8List.fromList(serialNumber.encoded),
    publicKey: requireRsa
        ? _parseRsaPublicKey(subjectPublicKeyInfo, path)
        : null,
  );
}

RSAPublicKey _parseRsaPublicKey(DerValue subjectPublicKeyInfo, String path) {
  final spkiReader = subjectPublicKeyInfo.reader();
  final publicKeyAlgorithm = spkiReader.read(
    DerTag.sequence,
    'public key algorithm',
  );
  final publicKeyOid = Der.algorithmOid(
    publicKeyAlgorithm,
    'public key algorithm',
  );
  if (publicKeyOid != Oid.rsaEncryption) {
    throw AppleError(
      'Unsupported certificate public key algorithm in "$path": '
      '$publicKeyOid; RSA is required.',
    );
  }
  final publicKeyBits = spkiReader.read(DerTag.bitString, 'RSA public key');
  spkiReader.requireDone('certificate public key');
  // A BIT STRING's first octet counts unused trailing bits; DER keys are
  // whole bytes, so it must be zero and is stripped before parsing.
  final keyBits = publicKeyBits.value;
  if (keyBits.isEmpty || keyBits.first != 0) {
    throw const FormatException('invalid RSA public-key bit string');
  }
  final publicKeySequence = Der.single(
    Uint8List.sublistView(publicKeyBits.value, 1),
    DerTag.sequence,
    'RSA public key',
  );
  final publicKeyReader = publicKeySequence.reader();
  final modulus = Der.positiveInteger(
    publicKeyReader.read(DerTag.integer, 'RSA modulus'),
    'RSA modulus',
  );
  final exponent = Der.positiveInteger(
    publicKeyReader.read(DerTag.integer, 'RSA public exponent'),
    'RSA public exponent',
  );
  publicKeyReader.requireDone('RSA public key');
  return RSAPublicKey(modulus, exponent);
}

/// Fills in the human-readable names and validity window, which come from a
/// full X.509 parse rather than the minimal DER walk above.
ParsedCertificate _withCertificateMetadata(
  ParsedCertificate certificate,
  String pem,
) {
  final tbs = X509Utils.x509CertificateFromPem(pem).tbsCertificate;
  if (tbs == null) throw const FormatException('certificate has no TBS data');
  final validity = tbs.validity;
  return certificate.withMetadata(
    commonName: tbs.subject['2.5.4.3'] ?? '',
    issuerName: tbs.issuer['2.5.4.3'] ?? base64.encode(certificate.issuer),
    notBefore: validity.notBefore,
    notAfter: validity.notAfter,
  );
}

/// Walks issuer links from [leaf] up to a self-signed certificate, drawing
/// candidates from the profile, the embedded Apple certificates, and any
/// injected test roots.
///
/// Returns the intermediates only; the leaf is emitted separately by the CMS
/// builder. The result must anchor to an Apple root or signing is refused.
@internal
@useResult
List<Uint8List> buildCertificateChain({
  required ParsedCertificate leaf,
  required List<Uint8List> profileCertificates,
  required List<Uint8List> trustedRootCertificates,
  required DateTime now,
  required String profilePath,
}) {
  final candidates = _chainCandidates(
    profileCertificates: profileCertificates,
    trustedRootCertificates: trustedRootCertificates,
    profilePath: profilePath,
  );
  final chain = <Uint8List>[];
  final seen = <String>{base64.encode(leaf.der)};
  var current = leaf;

  // A self-signed certificate (issuer == subject) terminates the walk.
  while (!bytesEqual(current.issuer, current.subject)) {
    final issuer = _findUnseenIssuer(current, candidates, seen);
    if (issuer == null) {
      throw AppleError(
        'Could not build certificate chain for leaf issuer '
        '"${leaf.issuerName}": no certificate subject matches issuer '
        '"${current.issuerName}".',
      );
    }
    checkValidity(
      now,
      issuer.notBefore!,
      issuer.notAfter!,
      'Signing chain certificate "${issuer.commonName}" for leaf issuer '
      '"${leaf.issuerName}"',
    );
    chain.add(Uint8List.fromList(issuer.der));
    seen.add(base64.encode(issuer.der));
    current = issuer;
  }

  final trustedRoots = _trustedRootsBase64(trustedRootCertificates);
  final isAnchored = trustedRoots.contains(base64.encode(current.der));
  if (!isAnchored) {
    throw AppleError(
      'Could not build certificate chain for leaf issuer '
      '"${leaf.issuerName}": chain is not anchored to an Apple root.',
    );
  }
  return chain;
}

List<ParsedCertificate> _chainCandidates({
  required List<Uint8List> profileCertificates,
  required List<Uint8List> trustedRootCertificates,
  required String profilePath,
}) => <ParsedCertificate>[
  for (var index = 0; index < profileCertificates.length; index++)
    parseChainCertificate(
      profileCertificates[index],
      'certificate ${index + 1} in provisioning profile "$profilePath"',
    ),
  for (final entry in embeddedAppleCertificateBase64.entries)
    parseChainCertificate(
      Uint8List.fromList(base64.decode(entry.value)),
      'embedded ${entry.key}',
    ),
  for (var index = 0; index < trustedRootCertificates.length; index++)
    parseChainCertificate(
      trustedRootCertificates[index],
      'test trust root ${index + 1}',
    ),
];

ParsedCertificate? _findUnseenIssuer(
  ParsedCertificate current,
  List<ParsedCertificate> candidates,
  Set<String> seen,
) {
  for (final candidate in candidates) {
    final encoded = base64.encode(candidate.der);
    if (seen.contains(encoded)) continue;
    final issuedCurrent = bytesEqual(current.issuer, candidate.subject);
    if (issuedCurrent) return candidate;
  }
  return null;
}

Set<String> _trustedRootsBase64(List<Uint8List> trustedRootCertificates) => {
  ...embeddedAppleCertificateBase64.entries
      .where((entry) => entry.key.startsWith('Apple Root CA'))
      .map((entry) => base64.encode(base64.decode(entry.value))),
  ...trustedRootCertificates.map(base64.encode),
};

@internal
void checkValidity(
  DateTime now,
  DateTime notBefore,
  DateTime notAfter,
  String context,
) {
  final start = notBefore.toUtc();
  final end = notAfter.toUtc();
  if (now.isBefore(start.subtract(_notBeforeSkew))) {
    throw AppleError(
      '$context is not yet valid (starts ${start.toIso8601String()}, '
      'this machine reads ${now.toIso8601String()}). '
      'Apple issues these against its own clock - synchronise the system '
      'clock and time zone, then retry.',
    );
  }
  if (now.isAfter(end)) {
    throw AppleError('$context expired at ${end.toIso8601String()}.');
  }
}

/// Constant-time-ish byte equality: always compares every byte of equal-length
/// inputs rather than returning at the first difference.
@internal
@useResult
bool bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

PemBlock _decodePem(String pem) {
  final lines = const LineSplitter().convert(pem.trim());
  if (lines.length < 3) throw const FormatException('incomplete PEM block');
  final begin = RegExp(
    r'^-----BEGIN ([A-Z0-9 ]+)-----$',
  ).firstMatch(lines.first.trim());
  if (begin == null) throw const FormatException('invalid PEM begin marker');
  final label = begin.group(1)!;
  final hasMatchingEnd = lines.last.trim() == '-----END $label-----';
  if (!hasMatchingEnd) {
    throw const FormatException('invalid PEM end marker');
  }
  final body = lines.sublist(1, lines.length - 1).map(trim).join();
  if (body.isEmpty) throw const FormatException('empty PEM body');
  return PemBlock(label: label, bytes: Uint8List.fromList(base64.decode(body)));
}

/// Apple's portal clock is authoritative; the local machine's is not. A
/// certificate or profile minted seconds ago by Apple looks "not yet valid"
/// to any host whose clock lags, and Windows hosts routinely drift by minutes
/// between NTP syncs. One hour absorbs that drift while still rejecting
/// obviously-future material; `notAfter` remains strictly enforced.
const _notBeforeSkew = Duration(hours: 1);
