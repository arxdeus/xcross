import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart' show CryptoUtils, X509Utils;
import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/util/errors.dart';

/// Parsed signing material used to produce Apple code-signing CMS blobs.
class SigningAsset {
  SigningAsset._({
    required this.privateKey,
    required this.leafCertificateDer,
    required this.profileCmsBytes,
    required this.profilePlistBytes,
    required this.profile,
    required this.entitlements,
    required this.teamIdentifier,
    required this.applicationIdentifier,
    required this.applicationIdentifierPrefix,
    required this.certificateCommonName,
    required _ParsedCertificate certificate,
    required List<Uint8List> certificateChain,
  }) : _certificate = certificate,
       _certificateChain = certificateChain;

  final RSAPrivateKey privateKey;
  final Uint8List leafCertificateDer;
  final Uint8List profileCmsBytes;
  final Uint8List profilePlistBytes;
  final Map<String, Object?> profile;
  final Map<String, Object?> entitlements;
  final String teamIdentifier;
  final String applicationIdentifier;
  final String applicationIdentifierPrefix;
  final String certificateCommonName;
  final _ParsedCertificate _certificate;
  final List<Uint8List> _certificateChain;

  /// Loads and validates a PEM RSA key, PEM leaf certificate, and
  /// CMS-wrapped mobile provisioning profile.
  static Future<SigningAsset> load({
    required String privateKeyPemPath,
    required String certificatePemPath,
    required String provisioningProfilePath,
    DateTime? now,
    @visibleForTesting List<Uint8List> trustedRootCertificates = const [],
  }) async {
    final keyPem = await _readText(privateKeyPemPath, 'private key');
    final certificatePem = await _readText(certificatePemPath, 'certificate');
    final profileCms = await _readBytes(
      provisioningProfilePath,
      'provisioning profile',
    );

    final privateKey = _parsePrivateKey(keyPem, privateKeyPemPath);
    final certificate = _parseCertificatePem(
      certificatePem,
      certificatePemPath,
    );
    final profileContent = _parseProfileCms(
      profileCms,
      provisioningProfilePath,
    );
    final profile = _parsePlist(profileContent.plist, provisioningProfilePath);
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    if (privateKey.modulus != certificate.publicKey!.modulus ||
        privateKey.publicExponent != certificate.publicKey!.publicExponent) {
      throw XcrossError(
        'RSA private key "$privateKeyPemPath" does not match certificate '
        '"$certificatePemPath".',
      );
    }

    _checkValidity(
      effectiveNow,
      certificate.notBefore!,
      certificate.notAfter!,
      'Certificate "$certificatePemPath"',
    );

    final creationDate = _requiredDate(
      profile,
      'CreationDate',
      provisioningProfilePath,
    );
    final expirationDate = _requiredDate(
      profile,
      'ExpirationDate',
      provisioningProfilePath,
    );
    _checkValidity(
      effectiveNow,
      creationDate,
      expirationDate,
      'Provisioning profile "$provisioningProfilePath"',
    );

    final developerCertificates = _developerCertificates(
      profile,
      provisioningProfilePath,
    );
    if (!developerCertificates.any(
      (candidate) => _bytesEqual(candidate, certificate.der),
    )) {
      throw XcrossError(
        'Certificate "$certificatePemPath" is absent from '
        'DeveloperCertificates in provisioning profile '
        '"$provisioningProfilePath".',
      );
    }

    final teamIdentifier = _requiredFirstString(
      profile,
      'TeamIdentifier',
      provisioningProfilePath,
    );
    final entitlements = _requiredMap(
      profile['Entitlements'],
      'Entitlements',
      provisioningProfilePath,
    );
    final applicationIdentifier = entitlements['application-identifier'];
    if (applicationIdentifier is! String || applicationIdentifier.isEmpty) {
      throw XcrossError(
        'Provisioning profile "$provisioningProfilePath" is missing '
        'Entitlements.application-identifier.',
      );
    }
    final prefixes = profile['ApplicationIdentifierPrefix'];
    final applicationIdentifierPrefix =
        prefixes is List<Object?> &&
            prefixes.isNotEmpty &&
            prefixes.first is String &&
            (prefixes.first! as String).isNotEmpty
        ? prefixes.first! as String
        : applicationIdentifier.split('.').first;
    final certificateChain = _buildCertificateChain(
      leaf: certificate,
      profileCertificates: profileContent.certificates,
      trustedRootCertificates: trustedRootCertificates,
      now: effectiveNow,
      profilePath: provisioningProfilePath,
    );

    return SigningAsset._(
      privateKey: privateKey,
      leafCertificateDer: Uint8List.fromList(certificate.der),
      profileCmsBytes: Uint8List.fromList(profileCms),
      profilePlistBytes: Uint8List.fromList(profileContent.plist),
      profile: Map.unmodifiable(profile),
      entitlements: Map.unmodifiable(entitlements),
      teamIdentifier: teamIdentifier,
      applicationIdentifier: applicationIdentifier,
      applicationIdentifierPrefix: applicationIdentifierPrefix,
      certificateCommonName: certificate.commonName,
      certificate: certificate,
      certificateChain: certificateChain,
    );
  }

  /// Builds detached CMS SignedData for [codeDirectoryBytes].
  ///
  /// [cdhashBytes] is the full 32-byte SHA-256 CodeDirectory hash. Apple's
  /// legacy cdhash plist receives its first 20 bytes, while CDHashes2 receives
  /// all 32 bytes. Supplying [signingTime] makes the output deterministic.
  Uint8List buildDetachedCms({
    required Uint8List codeDirectoryBytes,
    required Uint8List cdhashBytes,
    DateTime? signingTime,
  }) {
    if (cdhashBytes.length != 32) {
      throw ArgumentError.value(
        cdhashBytes.length,
        'cdhashBytes',
        'must contain a full 32-byte SHA-256 hash',
      );
    }

    final digest = Uint8List.fromList(
      crypto.sha256.convert(codeDirectoryBytes).bytes,
    );
    final cdhashPlist = utf8.encode(
      PropertyListSerialization.stringWithPropertyList({
        'cdhashes': [
          ByteData.sublistView(Uint8List.fromList(cdhashBytes.sublist(0, 20))),
        ],
      }),
    );
    final attributes = <Uint8List>[
      _attribute(_oidContentType, [_oid(_oidData)]),
      _attribute(_oidSigningTime, [_time(signingTime ?? DateTime.now())]),
      _attribute(_oidMessageDigest, [_octet(digest)]),
      _attribute(_oidAppleCdHashes, [_octet(cdhashPlist)]),
      _attribute(_oidAppleCdHashes2, [
        _sequence([_oid(_oidSha256), _octet(cdhashBytes)]),
      ]),
    ];
    final signedAttributesContent = _sortedContent(attributes);
    final signedAttributes = _tlv(0x31, signedAttributesContent);

    final signer = Signer('SHA-256/RSA')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final signature =
        (signer.generateSignature(signedAttributes) as RSASignature).bytes;

    final signerInfo = _sequence([
      _integer(1),
      _sequence([_certificate.issuer, _certificate.serialNumber]),
      _algorithmIdentifier(_oidSha256, includeNull: false),
      _tlv(0xa0, signedAttributesContent),
      _algorithmIdentifier(_oidRsaEncryption),
      _octet(signature),
    ]);

    final certificates = <Uint8List>[leafCertificateDer, ..._certificateChain];
    final uniqueCertificates = <String, Uint8List>{};
    for (final certificate in certificates) {
      uniqueCertificates[base64.encode(certificate)] = certificate;
    }

    final signedData = _sequence([
      _integer(1),
      _set([_algorithmIdentifier(_oidSha256, includeNull: false)]),
      _sequence([_oid(_oidData)]),
      _tlv(0xa0, _sortedContent(uniqueCertificates.values)),
      _set([signerInfo]),
    ]);
    return _sequence([_oid(_oidSignedData), _tlv(0xa0, signedData)]);
  }
}

const _oidData = '1.2.840.113549.1.7.1';
const _oidSignedData = '1.2.840.113549.1.7.2';
const _oidContentType = '1.2.840.113549.1.9.3';
const _oidMessageDigest = '1.2.840.113549.1.9.4';
const _oidSigningTime = '1.2.840.113549.1.9.5';
const _oidRsaEncryption = '1.2.840.113549.1.1.1';
const _oidSha256 = '2.16.840.1.101.3.4.2.1';
const _oidAppleCdHashes = '1.2.840.113635.100.9.1';
const _oidAppleCdHashes2 = '1.2.840.113635.100.9.2';

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

List<Uint8List> _buildCertificateChain({
  required _ParsedCertificate leaf,
  required List<Uint8List> profileCertificates,
  required List<Uint8List> trustedRootCertificates,
  required DateTime now,
  required String profilePath,
}) {
  final candidates = <_ParsedCertificate>[
    for (var index = 0; index < profileCertificates.length; index++)
      _parseChainCertificate(
        profileCertificates[index],
        'certificate ${index + 1} in provisioning profile "$profilePath"',
      ),
    for (final entry in _embeddedAppleCertificateBase64.entries)
      _parseChainCertificate(
        Uint8List.fromList(base64.decode(entry.value)),
        'embedded ${entry.key}',
      ),
    for (var index = 0; index < trustedRootCertificates.length; index++)
      _parseChainCertificate(
        trustedRootCertificates[index],
        'test trust root ${index + 1}',
      ),
  ];
  final chain = <Uint8List>[];
  final seen = <String>{base64.encode(leaf.der)};
  var current = leaf;

  while (!_bytesEqual(current.issuer, current.subject)) {
    _ParsedCertificate? issuer;
    for (final candidate in candidates) {
      final encoded = base64.encode(candidate.der);
      if (!seen.contains(encoded) &&
          _bytesEqual(current.issuer, candidate.subject)) {
        issuer = candidate;
        break;
      }
    }
    if (issuer == null) {
      throw XcrossError(
        'Could not build certificate chain for leaf issuer '
        '"${leaf.issuerName}": no certificate subject matches issuer '
        '"${current.issuerName}".',
      );
    }
    _checkValidity(
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
    throw XcrossError(
      'Could not build certificate chain for leaf issuer '
      '"${leaf.issuerName}": chain is not anchored to an Apple root.',
    );
  }
  return chain;
}

_ParsedCertificate _parseChainCertificate(Uint8List der, String context) {
  try {
    return _withCertificateMetadata(
      _parseCertificate(der, context),
      '-----BEGIN CERTIFICATE-----\n${base64.encode(der)}\n'
      '-----END CERTIFICATE-----',
    );
  } on Object catch (error) {
    throw XcrossError('Malformed $context: $error');
  }
}

Future<String> _readText(String path, String description) async {
  try {
    return await File(path).readAsString();
  } on Object catch (error) {
    throw XcrossError('Could not read $description "$path": $error');
  }
}

Future<Uint8List> _readBytes(String path, String description) async {
  try {
    return await File(path).readAsBytes();
  } on Object catch (error) {
    throw XcrossError('Could not read $description "$path": $error');
  }
}

RSAPrivateKey _parsePrivateKey(String pem, String path) {
  try {
    final decoded = _decodePem(pem);
    switch (decoded.label) {
      case 'PRIVATE KEY':
        final root = _single(decoded.bytes, 0x30, 'PKCS#8 private key');
        final reader = root.reader();
        reader.read(0x02, 'PKCS#8 version');
        final algorithm = reader.read(0x30, 'PKCS#8 algorithm');
        if (_algorithmOid(algorithm, 'PKCS#8 algorithm') != _oidRsaEncryption) {
          throw XcrossError(
            'Unsupported private key algorithm in "$path"; RSA is required.',
          );
        }
        reader.read(0x04, 'PKCS#8 private key data');
        reader.requireDone('PKCS#8 private key');
        return CryptoUtils.rsaPrivateKeyFromPem(pem);
      case 'RSA PRIVATE KEY':
        _single(decoded.bytes, 0x30, 'PKCS#1 private key');
        return CryptoUtils.rsaPrivateKeyFromPemPkcs1(pem);
      default:
        throw XcrossError(
          'Unsupported private key algorithm in "$path"; RSA PEM is required.',
        );
    }
  } on XcrossError {
    rethrow;
  } on Object catch (error) {
    throw XcrossError('Malformed RSA private key "$path": $error');
  }
}

_ParsedCertificate _parseCertificatePem(String pem, String path) {
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
  } on XcrossError {
    rethrow;
  } on Object catch (error) {
    throw XcrossError('Malformed certificate "$path": $error');
  }
}

_ParsedCertificate _parseCertificate(
  Uint8List der,
  String path, {
  bool requireRsa = false,
}) {
  final certificate = _single(der, 0x30, 'certificate');
  final certificateReader = certificate.reader();
  final tbs = certificateReader.read(0x30, 'TBSCertificate');
  final outerSignature = certificateReader.read(
    0x30,
    'certificate signature algorithm',
  );
  certificateReader.read(0x03, 'certificate signature');
  certificateReader.requireDone('certificate');

  final outerSignatureOid = _algorithmOid(
    outerSignature,
    'certificate signature algorithm',
  );

  final tbsReader = tbs.reader();
  if (tbsReader.peekTag() == 0xa0) {
    tbsReader.read(0xa0, 'certificate version');
  }
  final serialNumber = tbsReader.read(0x02, 'certificate serial number');
  final tbsSignature = tbsReader.read(0x30, 'TBS signature algorithm');
  if (_algorithmOid(tbsSignature, 'TBS signature algorithm') !=
      outerSignatureOid) {
    throw const FormatException('certificate signature algorithms differ');
  }
  final issuer = tbsReader.read(0x30, 'certificate issuer');
  tbsReader.read(0x30, 'certificate validity');
  final subject = tbsReader.read(0x30, 'certificate subject');
  final subjectPublicKeyInfo = tbsReader.read(0x30, 'certificate public key');

  RSAPublicKey? publicKey;
  if (requireRsa) {
    final spkiReader = subjectPublicKeyInfo.reader();
    final publicKeyAlgorithm = spkiReader.read(0x30, 'public key algorithm');
    final publicKeyOid = _algorithmOid(
      publicKeyAlgorithm,
      'public key algorithm',
    );
    if (publicKeyOid != _oidRsaEncryption) {
      throw XcrossError(
        'Unsupported certificate public key algorithm in "$path": '
        '$publicKeyOid; RSA is required.',
      );
    }
    final publicKeyBits = spkiReader.read(0x03, 'RSA public key');
    spkiReader.requireDone('certificate public key');
    if (publicKeyBits.value.isEmpty || publicKeyBits.value.first != 0) {
      throw const FormatException('invalid RSA public-key bit string');
    }
    final publicKeySequence = _single(
      Uint8List.sublistView(publicKeyBits.value, 1),
      0x30,
      'RSA public key',
    );
    final publicKeyReader = publicKeySequence.reader();
    final modulus = _positiveInteger(
      publicKeyReader.read(0x02, 'RSA modulus'),
      'RSA modulus',
    );
    final exponent = _positiveInteger(
      publicKeyReader.read(0x02, 'RSA public exponent'),
      'RSA public exponent',
    );
    publicKeyReader.requireDone('RSA public key');
    publicKey = RSAPublicKey(modulus, exponent);
  }

  return _ParsedCertificate(
    der: Uint8List.fromList(der),
    issuer: Uint8List.fromList(issuer.encoded),
    subject: Uint8List.fromList(subject.encoded),
    serialNumber: Uint8List.fromList(serialNumber.encoded),
    publicKey: publicKey,
  );
}

_ParsedCertificate _withCertificateMetadata(
  _ParsedCertificate certificate,
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

_ProfileCms _parseProfileCms(Uint8List bytes, String path) {
  try {
    final contentInfo = _single(bytes, 0x30, 'mobileprovision ContentInfo');
    final contentInfoReader = contentInfo.reader();
    final contentType = _oidValue(
      contentInfoReader.read(0x06, 'mobileprovision content type'),
    );
    if (contentType != _oidSignedData) {
      throw FormatException('expected SignedData, found $contentType');
    }
    final explicitSignedData = contentInfoReader.read(
      0xa0,
      'mobileprovision SignedData',
    );
    contentInfoReader.requireDone('mobileprovision ContentInfo');
    final signedData = _single(
      explicitSignedData.value,
      0x30,
      'mobileprovision SignedData',
    );
    final signedDataReader = signedData.reader();
    signedDataReader.read(0x02, 'SignedData version');
    signedDataReader.read(0x31, 'SignedData digest algorithms');
    final encapsulatedContentInfo = signedDataReader.read(
      0x30,
      'encapsulated profile',
    );
    final encapsulatedReader = encapsulatedContentInfo.reader();
    final encapsulatedType = _oidValue(
      encapsulatedReader.read(0x06, 'encapsulated content type'),
    );
    if (encapsulatedType != _oidData) {
      throw FormatException(
        'expected encapsulated data, found $encapsulatedType',
      );
    }
    final explicitContent = encapsulatedReader.read(
      0xa0,
      'encapsulated profile content',
    );
    encapsulatedReader.requireDone('encapsulated profile');
    final plist = _single(
      explicitContent.value,
      0x04,
      'encapsulated profile plist',
    ).value;
    if (plist.isEmpty) {
      throw const FormatException('encapsulated profile plist is empty');
    }

    final certificates = <Uint8List>[];
    var foundSignerInfos = false;
    while (!signedDataReader.isDone) {
      final tag = signedDataReader.peekTag();
      if (tag == 0xa0) {
        if (certificates.isNotEmpty) {
          throw const FormatException('duplicate certificate set');
        }
        final certificateSet = signedDataReader.read(
          0xa0,
          'profile certificate set',
        );
        final certificateReader = certificateSet.reader();
        while (!certificateReader.isDone) {
          final embedded = certificateReader.read(
            0x30,
            'embedded profile certificate',
          );
          _validateCertificateShape(embedded);
          certificates.add(Uint8List.fromList(embedded.encoded));
        }
      } else if (tag == 0xa1) {
        signedDataReader.read(0xa1, 'SignedData revocation data');
      } else if (tag == 0x31) {
        signedDataReader.read(0x31, 'SignedData signer infos');
        foundSignerInfos = true;
        if (!signedDataReader.isDone) {
          throw const FormatException('data follows SignedData signer infos');
        }
      } else {
        throw FormatException(
          'unexpected SignedData field 0x${tag.toRadixString(16)}',
        );
      }
    }
    if (!foundSignerInfos) {
      throw const FormatException('SignedData signer infos are missing');
    }
    return _ProfileCms(
      plist: Uint8List.fromList(plist),
      certificates: certificates,
    );
  } on Object catch (error) {
    throw XcrossError('Malformed mobileprovision CMS "$path": $error');
  }
}

void _validateCertificateShape(_DerValue certificate) {
  final reader = certificate.reader();
  reader.read(0x30, 'embedded TBSCertificate');
  reader.read(0x30, 'embedded certificate algorithm');
  reader.read(0x03, 'embedded certificate signature');
  reader.requireDone('embedded certificate');
}

Map<String, Object?> _parsePlist(Uint8List bytes, String path) {
  try {
    final Object value;
    if (bytes.length >= 8 && ascii.decode(bytes.sublist(0, 8)) == 'bplist00') {
      value = PropertyListSerialization.propertyListWithData(
        ByteData.sublistView(bytes),
      );
    } else {
      value = PropertyListSerialization.propertyListWithString(
        utf8.decode(bytes),
      );
    }
    return _requiredMap(value, 'root property list', path);
  } on XcrossError {
    rethrow;
  } on Object catch (error) {
    throw XcrossError('Malformed provisioning plist in "$path": $error');
  }
}

Map<String, Object?> _requiredMap(Object? value, String field, String path) {
  if (value is! Map<Object?, Object?>) {
    throw XcrossError(
      'Provisioning profile "$path" has an invalid $field map.',
    );
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw XcrossError(
        'Provisioning profile "$path" has a non-string key in $field.',
      );
    }
    result[entry.key! as String] = entry.value;
  }
  return result;
}

DateTime _requiredDate(Map<String, Object?> profile, String key, String path) {
  final value = profile[key];
  if (value is! DateTime) {
    throw XcrossError('Provisioning profile "$path" is missing valid $key.');
  }
  return value;
}

String _requiredFirstString(
  Map<String, Object?> profile,
  String key,
  String path,
) {
  final value = profile[key];
  if (value is! List<Object?> ||
      value.isEmpty ||
      value.first is! String ||
      (value.first! as String).isEmpty) {
    throw XcrossError('Provisioning profile "$path" is missing $key.');
  }
  return value.first! as String;
}

List<Uint8List> _developerCertificates(
  Map<String, Object?> profile,
  String path,
) {
  final value = profile['DeveloperCertificates'];
  if (value is! List<Object?> || value.isEmpty) {
    throw XcrossError(
      'Provisioning profile "$path" has no DeveloperCertificates.',
    );
  }
  return value.map((item) {
    if (item is ByteData) {
      return Uint8List.fromList(
        item.buffer.asUint8List(item.offsetInBytes, item.lengthInBytes),
      );
    }
    if (item is Uint8List) return Uint8List.fromList(item);
    throw XcrossError(
      'Provisioning profile "$path" contains a malformed '
      'DeveloperCertificates entry.',
    );
  }).toList();
}

void _checkValidity(
  DateTime now,
  DateTime notBefore,
  DateTime notAfter,
  String context,
) {
  if (now.isBefore(notBefore.toUtc())) {
    throw XcrossError(
      '$context is not yet valid (starts ${notBefore.toUtc().toIso8601String()}).',
    );
  }
  if (now.isAfter(notAfter.toUtc())) {
    throw XcrossError(
      '$context expired at ${notAfter.toUtc().toIso8601String()}.',
    );
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
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
  final body = lines
      .sublist(1, lines.length - 1)
      .map((line) => line.trim())
      .join();
  if (body.isEmpty) throw const FormatException('empty PEM body');
  return (label: label, bytes: Uint8List.fromList(base64.decode(body)));
}

String _algorithmOid(_DerValue algorithm, String context) {
  final reader = algorithm.reader();
  final oid = _oidValue(reader.read(0x06, '$context OID'));
  if (!reader.isDone) {
    final parameters = reader.read(null, '$context parameters');
    if (parameters.tag != 0x05 || parameters.value.isNotEmpty) {
      throw FormatException('$context has unsupported parameters');
    }
  }
  reader.requireDone(context);
  return oid;
}

BigInt _positiveInteger(_DerValue value, String context) {
  final bytes = value.value;
  if (bytes.isEmpty || bytes.first >= 0x80) {
    throw FormatException('$context is not a positive integer');
  }
  if (bytes.length > 1 && bytes.first == 0 && bytes[1] < 0x80) {
    throw FormatException('$context has redundant leading zeroes');
  }
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

_DerValue _single(Uint8List bytes, int tag, String context) {
  final reader = _DerReader(bytes);
  final value = reader.read(tag, context);
  reader.requireDone(context);
  return value;
}

Uint8List _attribute(String oid, List<Uint8List> values) =>
    _sequence([_oid(oid), _set(values)]);

Uint8List _algorithmIdentifier(String oid, {bool includeNull = true}) =>
    _sequence([_oid(oid), if (includeNull) _tlv(0x05, const [])]);

Uint8List _sequence(Iterable<Uint8List> values) => _tlv(0x30, _concat(values));

Uint8List _set(Iterable<Uint8List> values) =>
    _tlv(0x31, _sortedContent(values));

Uint8List _octet(List<int> bytes) => _tlv(0x04, bytes);

Uint8List _integer(int value) {
  if (value < 0) throw ArgumentError.value(value, 'value');
  final bytes = <int>[];
  var remaining = value;
  do {
    bytes.insert(0, remaining & 0xff);
    remaining >>= 8;
  } while (remaining != 0);
  if (bytes.first >= 0x80) bytes.insert(0, 0);
  return _tlv(0x02, bytes);
}

Uint8List _time(DateTime value) {
  final utc = value.toUtc();
  String two(int part) => part.toString().padLeft(2, '0');
  if (utc.year >= 1950 && utc.year <= 2049) {
    return _tlv(
      0x17,
      ascii.encode(
        '${two(utc.year % 100)}${two(utc.month)}${two(utc.day)}'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z',
      ),
    );
  }
  return _tlv(
    0x18,
    ascii.encode(
      '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}'
      '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z',
    ),
  );
}

Uint8List _oid(String value) {
  final arcs = value.split('.').map(int.parse).toList();
  if (arcs.length < 2 ||
      arcs.first < 0 ||
      arcs.first > 2 ||
      arcs[1] < 0 ||
      (arcs.first < 2 && arcs[1] >= 40)) {
    throw ArgumentError.value(value, 'value', 'invalid object identifier');
  }
  final body = <int>[
    ..._base128(arcs.first * 40 + arcs[1]),
    for (final arc in arcs.skip(2)) ..._base128(arc),
  ];
  return _tlv(0x06, body);
}

List<int> _base128(int value) {
  if (value < 0) throw ArgumentError.value(value, 'value');
  final bytes = <int>[value & 0x7f];
  var remaining = value >> 7;
  while (remaining > 0) {
    bytes.insert(0, (remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  return bytes;
}

Uint8List _tlv(int tag, Iterable<int> value) {
  final body = value is Uint8List ? value : Uint8List.fromList(value.toList());
  return Uint8List.fromList([tag, ..._length(body.length), ...body]);
}

List<int> _length(int value) {
  if (value < 128) return [value];
  final bytes = <int>[];
  var remaining = value;
  while (remaining > 0) {
    bytes.insert(0, remaining & 0xff);
    remaining >>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
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
    final result = left[index].compareTo(right[index]);
    if (result != 0) return result;
  }
  return left.length.compareTo(right.length);
}

String _oidValue(_DerValue value) {
  if (value.value.isEmpty) throw const FormatException('empty OID');
  final subIdentifiers = <BigInt>[];
  var current = BigInt.zero;
  var continued = false;
  for (final byte in value.value) {
    current = (current << 7) | BigInt.from(byte & 0x7f);
    continued = byte & 0x80 != 0;
    if (!continued) {
      subIdentifiers.add(current);
      current = BigInt.zero;
    }
  }
  if (continued || subIdentifiers.isEmpty) {
    throw const FormatException('unterminated OID');
  }
  final first = subIdentifiers.first;
  final firstArc = first < BigInt.from(40)
      ? BigInt.zero
      : first < BigInt.from(80)
      ? BigInt.one
      : BigInt.two;
  final secondArc = first - firstArc * BigInt.from(40);
  return [firstArc, secondArc, ...subIdentifiers.skip(1)].join('.');
}

class _ProfileCms {
  const _ProfileCms({required this.plist, required this.certificates});

  final Uint8List plist;
  final List<Uint8List> certificates;
}

class _ParsedCertificate {
  const _ParsedCertificate({
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
  final RSAPublicKey? publicKey;
  final String commonName;
  final String issuerName;
  final DateTime? notBefore;
  final DateTime? notAfter;

  _ParsedCertificate withMetadata({
    required String commonName,
    required String issuerName,
    required DateTime notBefore,
    required DateTime notAfter,
  }) => _ParsedCertificate(
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

class _DerReader {
  _DerReader(this._bytes, [int start = 0, int? end])
    : _offset = start,
      _end = end ?? _bytes.length {
    if (start < 0 || _end < start || _end > _bytes.length) {
      throw const FormatException('invalid DER bounds');
    }
  }

  final Uint8List _bytes;
  int _offset;
  final int _end;

  bool get isDone => _offset == _end;

  int peekTag() {
    if (isDone) throw const FormatException('unexpected end of DER');
    return _bytes[_offset];
  }

  _DerValue read(int? expectedTag, String context) {
    if (_offset >= _end) {
      throw FormatException('$context is missing');
    }
    final start = _offset;
    final tag = _bytes[_offset++];
    if (tag & 0x1f == 0x1f) {
      throw FormatException('$context uses unsupported high-tag-number form');
    }
    if (_offset >= _end) throw FormatException('$context has no DER length');
    final firstLength = _bytes[_offset++];
    int length;
    if (firstLength == 0x80) {
      throw FormatException('$context uses indefinite-length encoding');
    }
    if (firstLength & 0x80 == 0) {
      length = firstLength;
    } else {
      final count = firstLength & 0x7f;
      if (count == 0 || count > 4 || _offset + count > _end) {
        throw FormatException('$context has an invalid DER length');
      }
      if (_bytes[_offset] == 0) {
        throw FormatException('$context has a non-canonical DER length');
      }
      length = 0;
      for (var index = 0; index < count; index++) {
        length = (length << 8) | _bytes[_offset++];
      }
      if (length < 128) {
        throw FormatException('$context has a non-canonical DER length');
      }
    }
    if (length > _end - _offset) {
      throw FormatException('$context exceeds its DER container');
    }
    final valueStart = _offset;
    _offset += length;
    if (expectedTag != null && tag != expectedTag) {
      throw FormatException(
        '$context has tag 0x${tag.toRadixString(16)}, expected '
        '0x${expectedTag.toRadixString(16)}',
      );
    }
    return _DerValue(
      bytes: _bytes,
      start: start,
      valueStart: valueStart,
      end: _offset,
      tag: tag,
    );
  }

  void requireDone(String context) {
    if (!isDone) throw FormatException('$context has trailing DER data');
  }
}

class _DerValue {
  const _DerValue({
    required this.bytes,
    required this.start,
    required this.valueStart,
    required this.end,
    required this.tag,
  });

  final Uint8List bytes;
  final int start;
  final int valueStart;
  final int end;
  final int tag;

  Uint8List get encoded => Uint8List.sublistView(bytes, start, end);
  Uint8List get value => Uint8List.sublistView(bytes, valueStart, end);
  _DerReader reader() => _DerReader(bytes, valueStart, end);
}
