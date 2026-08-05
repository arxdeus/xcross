import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/signing/der.dart';
import 'package:apple_developer_kit/src/signing/provisioning_profile.dart';
import 'package:apple_developer_kit/src/signing/x509.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart';
import 'package:propertylistserialization/propertylistserialization.dart';

/// The identifiers a provisioning profile contributes to a signature.
typedef _ProfileIdentity = ({
  String teamIdentifier,
  Map<String, Object?> entitlements,
  String applicationIdentifier,
  String applicationIdentifierPrefix,
});

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
    required ParsedCertificate certificate,
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
  final ParsedCertificate _certificate;
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

    final privateKey = parsePrivateKey(keyPem, privateKeyPemPath);
    final certificate = parseCertificatePem(certificatePem, certificatePemPath);
    final profileContent = parseProfileCms(profileCms, provisioningProfilePath);
    final profile = parsePlist(profileContent.plist, provisioningProfilePath);
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    _requireKeyMatchesCertificate(
      privateKey,
      certificate,
      privateKeyPemPath,
      certificatePemPath,
    );
    _requireWithinValidityWindows(
      certificate: certificate,
      profile: profile,
      now: effectiveNow,
      certificatePath: certificatePemPath,
      profilePath: provisioningProfilePath,
    );
    _requireCertificateIsInProfile(
      certificate,
      profile,
      certificatePemPath,
      provisioningProfilePath,
    );

    final identity = _readIdentity(profile, provisioningProfilePath);
    final certificateChain = buildCertificateChain(
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
      entitlements: Map.unmodifiable(identity.entitlements),
      teamIdentifier: identity.teamIdentifier,
      applicationIdentifier: identity.applicationIdentifier,
      applicationIdentifierPrefix: identity.applicationIdentifierPrefix,
      certificateCommonName: certificate.commonName,
      certificate: certificate,
      certificateChain: certificateChain,
    );
  }

  /// Refuses a key and certificate that do not describe the same RSA pair.
  static void _requireKeyMatchesCertificate(
    RSAPrivateKey privateKey,
    ParsedCertificate certificate,
    String privateKeyPemPath,
    String certificatePemPath,
  ) {
    if (privateKey.modulus != certificate.publicKey!.modulus ||
        privateKey.publicExponent != certificate.publicKey!.publicExponent) {
      throw AppleError(
        'RSA private key "$privateKeyPemPath" does not match certificate '
        '"$certificatePemPath".',
      );
    }
  }

  static void _requireWithinValidityWindows({
    required ParsedCertificate certificate,
    required Map<String, Object?> profile,
    required DateTime now,
    required String certificatePath,
    required String profilePath,
  }) {
    checkValidity(
      now,
      certificate.notBefore!,
      certificate.notAfter!,
      'Certificate "$certificatePath"',
    );
    checkValidity(
      now,
      requiredDate(profile, 'CreationDate', profilePath),
      requiredDate(profile, 'ExpirationDate', profilePath),
      'Provisioning profile "$profilePath"',
    );
  }

  /// The profile enumerates the certificates it authorises; signing with one
  /// it does not list would produce a bundle the device rejects.
  static void _requireCertificateIsInProfile(
    ParsedCertificate certificate,
    Map<String, Object?> profile,
    String certificatePemPath,
    String profilePath,
  ) {
    final authorised = developerCertificates(profile, profilePath);
    if (!authorised.any(
      (candidate) => bytesEqual(candidate, certificate.der),
    )) {
      throw AppleError(
        'Certificate "$certificatePemPath" is absent from '
        'DeveloperCertificates in provisioning profile '
        '"$profilePath".',
      );
    }
  }

  static _ProfileIdentity _readIdentity(
    Map<String, Object?> profile,
    String profilePath,
  ) {
    final teamIdentifier = requiredFirstString(
      profile,
      'TeamIdentifier',
      profilePath,
    );
    final entitlements = requiredMap(
      profile['Entitlements'],
      'Entitlements',
      profilePath,
    );
    final applicationIdentifier = entitlements['application-identifier'];
    if (applicationIdentifier is! String || applicationIdentifier.isEmpty) {
      throw AppleError(
        'Provisioning profile "$profilePath" is missing '
        'Entitlements.application-identifier.',
      );
    }
    // The prefix is normally listed outright; older profiles only imply it as
    // the part of the application identifier before the first dot.
    final prefix = switch (profile['ApplicationIdentifierPrefix']) {
      [final String first, ...] when first.isNotEmpty => first,
      _ => applicationIdentifier.split('.').first,
    };
    return (
      teamIdentifier: teamIdentifier,
      entitlements: entitlements,
      applicationIdentifier: applicationIdentifier,
      applicationIdentifierPrefix: prefix,
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

    final signedAttributesContent = _signedAttributes(
      codeDirectoryBytes: codeDirectoryBytes,
      cdhashBytes: cdhashBytes,
      signingTime: signingTime ?? DateTime.now(),
    );

    // The signature is computed over an explicit SET OF, but SignerInfo embeds
    // the very same content under an implicit [0]. CMS requires that swap.
    final signer = Signer('SHA-256/RSA')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final signature =
        (signer.generateSignature(Der.tlv(DerTag.set, signedAttributesContent))
                as RSASignature)
            .bytes;

    final signerInfo = Der.sequence([
      Der.unsignedInteger(1),
      Der.sequence([_certificate.issuer, _certificate.serialNumber]),
      Der.algorithmIdentifier(Oid.sha256, includeNull: false),
      Der.tlv(DerTag.context0, signedAttributesContent),
      Der.algorithmIdentifier(Oid.rsaEncryption),
      Der.octetString(signature),
    ]);

    final signedData = Der.sequence([
      Der.unsignedInteger(1),
      Der.setOf([Der.algorithmIdentifier(Oid.sha256, includeNull: false)]),
      Der.sequence([Der.oid(Oid.data)]),
      Der.tlv(DerTag.context0, Der.sortedContent(_uniqueCertificates())),
      Der.setOf([signerInfo]),
    ]);
    return Der.sequence([
      Der.oid(Oid.signedData),
      Der.tlv(DerTag.context0, signedData),
    ]);
  }

  /// The signed attributes, already concatenated in DER `SET OF` order so the
  /// same bytes can be reused under both the SET and the implicit `[0]` tag.
  Uint8List _signedAttributes({
    required Uint8List codeDirectoryBytes,
    required Uint8List cdhashBytes,
    required DateTime signingTime,
  }) {
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
    return Der.sortedContent(<Uint8List>[
      Der.attribute(Oid.contentType, [Der.oid(Oid.data)]),
      Der.attribute(Oid.signingTime, [Der.time(signingTime)]),
      Der.attribute(Oid.messageDigest, [Der.octetString(digest)]),
      Der.attribute(Oid.appleCdHashes, [Der.octetString(cdhashPlist)]),
      Der.attribute(Oid.appleCdHashes2, [
        Der.sequence([Der.oid(Oid.sha256), Der.octetString(cdhashBytes)]),
      ]),
    ]);
  }

  /// The leaf followed by its chain, deduplicated in case the profile already
  /// embedded an intermediate this signer also carries.
  Iterable<Uint8List> _uniqueCertificates() {
    final unique = <String, Uint8List>{};
    for (final certificate in [leafCertificateDer, ..._certificateChain]) {
      unique[base64.encode(certificate)] = certificate;
    }
    return unique.values;
  }

  static Future<String> _readText(String path, String description) async {
    try {
      return await File(path).readAsString();
    } on Object catch (error) {
      throw AppleError('Could not read $description "$path": $error');
    }
  }

  static Future<Uint8List> _readBytes(String path, String description) async {
    try {
      return await File(path).readAsBytes();
    } on Object catch (error) {
      throw AppleError('Could not read $description "$path": $error');
    }
  }
}
