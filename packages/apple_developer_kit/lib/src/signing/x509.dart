import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/signing/der.dart';
import 'package:basic_utils/basic_utils.dart' show CryptoUtils, X509Utils;
import 'package:pointycastle/export.dart';
import 'package:pure/pure.dart';

/// Object identifiers used by the certificate, profile, and CMS layers.
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
        if (Der.algorithmOid(algorithm, 'PKCS#8 algorithm') !=
            Oid.rsaEncryption) {
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
ParsedCertificate parseChainCertificate(Uint8List der, String context) {
  try {
    return _withCertificateMetadata(_parseCertificate(der, context), '''
-----BEGIN CERTIFICATE-----
${base64.encode(der)}
-----END CERTIFICATE-----''');
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
  // A mismatch here is the classic signature-substitution tell.
  if (Der.algorithmOid(tbsSignature, 'TBS signature algorithm') !=
      outerSignatureOid) {
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
  if (publicKeyBits.value.isEmpty || publicKeyBits.value.first != 0) {
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
List<Uint8List> buildCertificateChain({
  required ParsedCertificate leaf,
  required List<Uint8List> profileCertificates,
  required List<Uint8List> trustedRootCertificates,
  required DateTime now,
  required String profilePath,
}) {
  final candidates = <ParsedCertificate>[
    for (var index = 0; index < profileCertificates.length; index++)
      parseChainCertificate(
        profileCertificates[index],
        'certificate ${index + 1} in provisioning profile "$profilePath"',
      ),
    for (final entry in _embeddedAppleCertificateBase64.entries)
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
  final chain = <Uint8List>[];
  final seen = <String>{base64.encode(leaf.der)};
  var current = leaf;

  // A self-signed certificate (issuer == subject) terminates the walk.
  while (!bytesEqual(current.issuer, current.subject)) {
    ParsedCertificate? issuer;
    for (final candidate in candidates) {
      final encoded = base64.encode(candidate.der);
      if (!seen.contains(encoded) &&
          bytesEqual(current.issuer, candidate.subject)) {
        issuer = candidate;
        break;
      }
    }
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

  final trustedRoots = {
    ..._embeddedAppleCertificateBase64.entries
        .where((entry) => entry.key.startsWith('Apple Root CA'))
        .map((entry) => base64.encode(base64.decode(entry.value))),
    ...trustedRootCertificates.map(base64.encode),
  };
  if (!trustedRoots.contains(base64.encode(current.der))) {
    throw AppleError(
      'Could not build certificate chain for leaf issuer '
      '"${leaf.issuerName}": chain is not anchored to an Apple root.',
    );
  }
  return chain;
}

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
      '$context is not yet valid (starts ${start.toIso8601String()}).',
    );
  }
  if (now.isAfter(end)) {
    throw AppleError('$context expired at ${end.toIso8601String()}.');
  }
}

/// Constant-time-ish byte equality: always compares every byte of equal-length
/// inputs rather than returning at the first difference.
bool bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

({String label, Uint8List bytes}) _decodePem(String pem) {
  final lines = const LineSplitter().convert(pem.trim());
  if (lines.length < 3) throw const FormatException('incomplete PEM block');
  final begin = RegExp(
    r'^-----BEGIN ([A-Z0-9 ]+)-----$',
  ).firstMatch(lines.first.trim());
  if (begin == null) throw const FormatException('invalid PEM begin marker');
  final label = begin.group(1)!;
  if (lines.last.trim() != '-----END $label-----') {
    throw const FormatException('invalid PEM end marker');
  }
  final body = lines.sublist(1, lines.length - 1).map(trim).join();
  if (body.isEmpty) throw const FormatException('empty PEM body');
  return (label: label, bytes: Uint8List.fromList(base64.decode(body)));
}

// DER certificates from pinned zsign d6e929c src/openssl.cpp.
const _embeddedAppleCertificateBase64 = <String, String>{
  'Apple WWDR G2':
      'MIIC9zCCAnygAwIBAgIIb+/Y9emjp+4wCgYIKoZIzj0EAwIwZzEbMBkGA1UEAwwSQXBwbGUg'
      'Um9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTET'
      'MBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNTA2MjM0MzI0WhcNMjkw'
      'NTA2MjM0MzI0WjCBgDE0MDIGA1UEAwwrQXBwbGUgV29ybGR3aWRlIERldmVsb3BlciBSZWxh'
      'dGlvbnMgQ0EgLSBHMjEmMCQGA1UECwwdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx'
      'EzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0D'
      'AQcDQgAE3fC3BkvP3XMEE8RDiQOTgPte9nStQmFSWAImUxnIYyIHCVJhysTZV+9tJmiLdJGM'
      'xPmAaCj8CWjwENrp0C7JGqOB9zCB9DBGBggrBgEFBQcBAQQ6MDgwNgYIKwYBBQUHMAGGKmh0'
      'dHA6Ly9vY3NwLmFwcGxlLmNvbS9vY3NwMDQtYXBwbGVyb290Y2FnMzAdBgNVHQ4EFgQUhLaE'
      'zDqGYnIWWZToGqO9SN863wswDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBS7sN6hWDOI'
      'mqSKmd6+veuv2sskqzA3BgNVHR8EMDAuMCygKqAohiZodHRwOi8vY3JsLmFwcGxlLmNvbS9h'
      'cHBsZXJvb3RjYWczLmNybDAOBgNVHQ8BAf8EBAMCAQYwEAYKKoZIhvdjZAYCDwQCBQAwCgYI'
      'KoZIzj0EAwIDaQAwZgIxANmxxzHGI/ZPTdDZR8V9GGkRh3En02it4Jtlmr5s3z9GppAJvm6h'
      'OyywUYlBPIfSvwIxAPxkUolLPF2/axzCiZgvcq61m6oaCyNUd1ToFUOixRLal1BzfF7QbrJc'
      'YlDXUfE6Wg==',
  'Apple WWDR G3':
      'MIIEUTCCAzmgAwIBAgIQfK9pCiW3Of57m0R6wXjF7jANBgkqhkiG9w0BAQsFADBiMQswCQYD'
      'VQQGEwJVUzETMBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNh'
      'dGlvbiBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcNMjAwMjE5MTgxMzQ3'
      'WhcNMzAwMjIwMDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVy'
      'IFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzMxEzARBgNV'
      'BAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB'
      'CgKCAQEA2PWJ/KhZC4fHTJEuLVaQ03gdpDDppUjvC0O/LYT7JF1FG+XrWTYSXFRknmxiLbTG'
      'l8rMPPbWBpH85QKmHGq0edVny6zpPwcR4YS8Rx1mjjmi6LRJ7TrS4RBgeo6TjMrA2gzAg9Dj'
      '+ZHWp4zIwXPirkbRYp2SqJBgN31ols2N4Pyb+ni743uvLRfdW/6AWSN1F7gSwe0b5TTO/iK1'
      'nkmw5VW/j4SiPKi6xYaVFuQAyZ8D0MyzOhZ71gVcnetHrg21LYwOaU1A0EtMOwSejSGxrC5D'
      'VDDOwYqGlJhL32oNP/77HK6XF8J4CjDgXx9UO0m3JQAaN4LSVpelUkl8YDib7wIDAQABo4Hv'
      'MIHsMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/'
      'CF4wRAYIKwYBBQUHAQEEODA2MDQGCCsGAQUFBzABhihodHRwOi8vb2NzcC5hcHBsZS5jb20v'
      'b2NzcDAzLWFwcGxlcm9vdGNhMC4GA1UdHwQnMCUwI6AhoB+GHWh0dHA6Ly9jcmwuYXBwbGUu'
      'Y29tL3Jvb3QuY3JsMB0GA1UdDgQWBBQJ/sAVkPmvZAqSErkmKGMMl+ynsjAOBgNVHQ8BAf8E'
      'BAMCAQYwEAYKKoZIhvdjZAYCAQQCBQAwDQYJKoZIhvcNAQELBQADggEBAK1lE+j24IF3RAJH'
      'Qr5fpTkg6mKp/cWQyXMT1Z6b0KoPjY3L7QHPbChAW8dVJEH4/M/BtSPp3Ozxb8qAHXfCxGFJ'
      'JWevD8o5Ja3T43rMMygNDi6hV0Bz+uZcrgZRKe3jhQxPYdwyFot30ETKXXIDMUacrptAGvr0'
      '4NM++i+MZp+XxFRZ79JI9AeZSWBZGcfdlNHAwWx/eCHvDOs7bJmCS1JgOLU5gm3sUjFTvg+R'
      'TElJdI+mUcuER04ddSduvfnSXPN/wmwLCTbiZOTCNwMUGdXqapSqqdv+9poIZ4vvK7iqF0mD'
      'r8/LvOnP6pVxsLRFoszlh6oKw0E6eVzaUDSdlTs=',
  'Apple WWDR G4':
      'MIIEVTCCAz2gAwIBAgIUE9x3lVJx5T3GMujM/+Uh88zFztIwDQYJKoZIhvcNAQELBQAwYjEL'
      'MAkGA1UEBhMCVVMxEzARBgNVBAoTCkFwcGxlIEluYy4xJjAkBgNVBAsTHUFwcGxlIENlcnRp'
      'ZmljYXRpb24gQXV0aG9yaXR5MRYwFAYDVQQDEw1BcHBsZSBSb290IENBMB4XDTIwMTIxNjE5'
      'MzYwNFoXDTMwMTIxMDAwMDAwMFowdTFEMEIGA1UEAww7QXBwbGUgV29ybGR3aWRlIERldmVs'
      'b3BlciBSZWxhdGlvbnMgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxCzAJBgNVBAsMAkc0MRMw'
      'EQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzCCASIwDQYJKoZIhvcNAQEBBQADggEP'
      'ADCCAQoCggEBANAfeKp6JzKwRl/nF3bYoJ0OKY6tPTKlxGs3yeRBkWq3eXFdDDQEYHX3rkOP'
      'R8SGHgjov9Y5Ui8eZ/xx8YJtPH4GUnadLLzVQ+mxtLxAOnhRXVGhJeG+bJGdayFZGEHVD41t'
      'QSo5SiHgkJ9OE0/QjJoyuNdqkh4laqQyziIZhQVg3AJK8lrrd3kCfcCXVGySjnYB5kaP5eYq'
      '+6KwrRitbTOFOCOL6oqW7Z+uZk+jDEAnbZXQYojZQykn/e2kv1MukBVlPNkuYmQzHWxq3Y4h'
      'qqRfFcYw7V/mjDaSlLfcOQIA+2SM1AyB8j/VNJeHdSbCb64DYyEMe9QbsWLFApy9/a8CAwEA'
      'AaOB7zCB7DASBgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFCvQaUeUdgn+9GuNLkCm'
      '90dNfwheMEQGCCsGAQUFBwEBBDgwNjA0BggrBgEFBQcwAYYoaHR0cDovL29jc3AuYXBwbGUu'
      'Y29tL29jc3AwMy1hcHBsZXJvb3RjYTAuBgNVHR8EJzAlMCOgIaAfhh1odHRwOi8vY3JsLmFw'
      'cGxlLmNvbS9yb290LmNybDAdBgNVHQ4EFgQUW9n6HeeaGgujmXYiUIY+kchbd6gwDgYDVR0P'
      'AQH/BAQDAgEGMBAGCiqGSIb3Y2QGAgEEAgUAMA0GCSqGSIb3DQEBCwUAA4IBAQA/Vj2e5bbD'
      'eeZFIGi9v3OLLBKeAuOugCKMBB7DUshwgKj7zqew1UJEggOCTwb8O0kU+9h0UoWvp50h5wES'
      'A5/NQFjQAde/MoMrU1goPO6cn1R2PWQnxn6NHThNLa6B5rmluJyJlPefx4elUWY0GzlxOSTj'
      'h2fvpbFoe4zuPfeutnvi0v/fYcZqdUmVIkSoBPyUuAsuORFJEtHlgepZAE9bPFo22noicwkJ'
      'ac3AfOriJP6YRLj477JxPxpd1F1+M02cHSS+APCQA1iZQT0xWmJArzmoUUOSqwSonMJNsUvS'
      'q3xKX+udO7xPiEAGE/+QF4oIRynoYpgppU8RBWk6z/Kf',
  'Apple WWDR G5':
      'MIIEVTCCAz2gAwIBAgIUO36ACu7TAqHm7NuX2cqsKJzxaZQwDQYJKoZIhvcNAQELBQAwYjEL'
      'MAkGA1UEBhMCVVMxEzARBgNVBAoTCkFwcGxlIEluYy4xJjAkBgNVBAsTHUFwcGxlIENlcnRp'
      'ZmljYXRpb24gQXV0aG9yaXR5MRYwFAYDVQQDEw1BcHBsZSBSb290IENBMB4XDTIwMTIxNjE5'
      'Mzg1NloXDTMwMTIxMDAwMDAwMFowdTFEMEIGA1UEAww7QXBwbGUgV29ybGR3aWRlIERldmVs'
      'b3BlciBSZWxhdGlvbnMgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxCzAJBgNVBAsMAkc1MRMw'
      'EQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzCCASIwDQYJKoZIhvcNAQEBBQADggEP'
      'ADCCAQoCggEBAJ9d2h/7+rzQSyI8x9Ym+hf39J8ePmQRZprvXr6rNL2qLCFu1h6UIYUsdMEO'
      'EGGqPGNKfkrjyHXWz8KcCEh7arkpsclm/ciKFtGyBDyCuoBs4v8Kcuus/jtvSL6eixFNlX2y'
      'e5AvAhxO/Em+12+1T754xtress3J2WYRO1rpCUVziVDUTuJoBX7adZxLAa7a489tdE3eU9DV'
      'GjiCOtCd410pe7GB6iknC/tgfIYS+/BiTwbnTNEf2W2e7XPaeCENnXDZRleQX2eEwXN3Cqhi'
      'YraucIa7dSOJrXn25qTU/YMmMgo7JJJbIKGc0S+AGJvdPAvntf3sgFcPF54/K4cnu/cCAwEA'
      'AaOB7zCB7DASBgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFCvQaUeUdgn+9GuNLkCm'
      '90dNfwheMEQGCCsGAQUFBwEBBDgwNjA0BggrBgEFBQcwAYYoaHR0cDovL29jc3AuYXBwbGUu'
      'Y29tL29jc3AwMy1hcHBsZXJvb3RjYTAuBgNVHR8EJzAlMCOgIaAfhh1odHRwOi8vY3JsLmFw'
      'cGxlLmNvbS9yb290LmNybDAdBgNVHQ4EFgQUGYuXjUpbYXhX9KVcNRKKOQjjsHUwDgYDVR0P'
      'AQH/BAQDAgEGMBAGCiqGSIb3Y2QGAgEEAgUAMA0GCSqGSIb3DQEBCwUAA4IBAQBaxDWi2eYK'
      'nlKiAIIid81yL5D5Iq8UJcyqCkJgksK9dR3rTMoV5X5rQBBe+1tFdA3wen2Ikc7eY4tCidIY'
      '30GzWJ4GCIdI3UCvI9Xt6yxg5eukfxzpnIPWlF9MYjmKTq4TjX1DuNxerL4YQPLmDyxdE5Px'
      'e2WowmhI3v+0lpsM+zI2np4NlV84CouW0hJst4sLjtc+7G8Bqs5NRWDbhHFmYuUZZTDNiv9F'
      'U/tu+4h3Q8NIY/n3UbNyXnniVs+8u4S5OFp4rhFIUrsNNYuU3sx0mmj1SWCUrPKosxWGkNDM'
      'MEOG0+VwAlG0gcCol9Tq6rCMCUDvOJOyzSID62dDZchF',
  'Apple WWDR G6':
      'MIIDFjCCApygAwIBAgIUIsGhRwp0c2nvU4YSycafPTjzbNcwCgYIKoZIzj0EAwMwZzEbMBkG'
      'A1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u'
      'IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMjEwMzE3'
      'MjAzNzEwWhcNMzYwMzE5MDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2'
      'ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYx'
      'EzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACID'
      'YgAEbsQKC94PrlWmZXnXgtxzdVJL8T0SGYngDRGpngn3N6PT8JMEb7FDi4bBmPhCnZ3/sq6P'
      'F/cGcKXWsL5vOteRhyJ45x3ASP7cOB+aao90fcpxSv/EZFbniAbNgZGhIhpIo4H6MIH3MBIG'
      'A1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUu7DeoVgziJqkipnevr3rr9rLJKswRgYI'
      'KwYBBQUHAQEEOjA4MDYGCCsGAQUFBzABhipodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAz'
      'LWFwcGxlcm9vdGNhZzMwNwYDVR0fBDAwLjAsoCqgKIYmaHR0cDovL2NybC5hcHBsZS5jb20v'
      'YXBwbGVyb290Y2FnMy5jcmwwHQYDVR0OBBYEFD8vlCNR01DJmig97bB85c+lkGKZMA4GA1Ud'
      'DwEB/wQEAwIBBjAQBgoqhkiG92NkBgIBBAIFADAKBggqhkjOPQQDAwNoADBlAjBAXhSq5IyK'
      'ogMCPtw490BaB677CaEGJXufQB/EqZGd6CSjiCtOnuMTbXVXmxxcxfkCMQDTSPxarZXvNrkx'
      'U3TkUMI33yzvFVVRT4wxWJC994OsdcZ4+RGNsYDyR5gmdr0nDGg=',
  'Apple Root CA':
      'MIIEuzCCA6OgAwIBAgIBAjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzETMBEGA1UE'
      'ChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx'
      'FjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcNMDYwNDI1MjE0MDM2WhcNMzUwMjA5MjE0MDM2'
      'WjBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUg'
      'Q2VydGlmaWNhdGlvbiBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwggEiMA0G'
      'CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDkkakJH5HbHkdQ6wXtXnmELes2oldMVeyLGYne'
      '+Uts9QerIjAC6Bg++FAJ039BqJj50cpmnCRrEdCju+QbKsMflZ56DKRHi1vUFjczy8QPTc4U'
      'adHJGXL1XQ7Vf1+b8iUDulWPTV0N8WQ1IxVLFVkds5T39pyez1C6wVhQZ48ItCD3y6wsIG9w'
      'tj8BMIy3Q88PnT3zK0koGsj+zrW5DtleHNbLPbU6rfQPDgCSC7EhFi501TwN22IWq6NxkkdT'
      'VcGvL0Gz+PvjcM3mo0xFfh9Ma1CWQYnEdGILEINBhzOKgbEwWOxaBDKMaLOPHd5lc/9nXmW8'
      'Sdh2nzMUZaF3lMktAgMBAAGjggF6MIIBdjAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUw'
      'AwEB/zAdBgNVHQ4EFgQUK9BpR5R2Cf70a40uQKb3R01/CF4wHwYDVR0jBBgwFoAUK9BpR5R2'
      'Cf70a40uQKb3R01/CF4wggERBgNVHSAEggEIMIIBBDCCAQAGCSqGSIb3Y2QFATCB8jAqBggr'
      'BgEFBQcCARYeaHR0cHM6Ly93d3cuYXBwbGUuY29tL2FwcGxlY2EvMIHDBggrBgEFBQcCAjCB'
      'thqBs1JlbGlhbmNlIG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMg'
      'YWNjZXB0YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBj'
      'b25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZpY2F0aW9u'
      'IHByYWN0aWNlIHN0YXRlbWVudHMuMA0GCSqGSIb3DQEBBQUAA4IBAQBcNplMLXi37Yyb3PN3'
      'm/J20ncwT8EfhYOFG5k9RzfyqZtAjizUsZAS2L70c5vu0mQPy3lPNNiiPvl4/2vIB+x9OYOL'
      'UyDTOMSxv5pPCmv/K/xZpwUJfBdAVhEedNO3iyM7R6PVbyTi69G3cN8PReEnyvFteO3ntRcX'
      'qNx+IjXKJdXZD9Zr1KIkIxH3oayPc4FgxhtbCS+SsvhESPBgOJ4V9T0mZyCKM2r3DYLP3uuj'
      'L/lTaltkwGMzd/c6ByxW69oPIQ7aunMZT7XZNn/Bh1XZp5m5MkL72NVxnn6hUrcbvZNCJBIq'
      'xw8dtk2cXmPIS4AXUKqK1drk/NAJBzewdXUh',
  'Apple Root CA - G3':
      'MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUg'
      'Um9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTET'
      'MBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkw'
      'NDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFw'
      'cGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYD'
      'VQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHc'
      'FBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dv'
      'MVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr'
      'MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD'
      '6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK'
      '1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==',
};

/// Apple's portal clock is often a few seconds ahead of the local machine;
/// freshly issued profiles then fail a strict `CreationDate` check. Five
/// minutes covers NTP drift without accepting obviously-future material.
const _notBeforeSkew = Duration(minutes: 5);
