import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/signing/der.dart';
import 'package:apple_developer_kit/src/signing/plist.dart';
import 'package:apple_developer_kit/src/signing/x509.dart';

/// The payload of a `.mobileprovision`: the embedded plist and the
/// certificates Apple shipped alongside it.
typedef ProfileCms = ({Uint8List plist, List<Uint8List> certificates});

/// Unwraps the CMS `SignedData` that a `.mobileprovision` is packaged in.
///
/// The signature itself is not verified here: the profile is only trusted
/// because the leaf certificate must also appear in `DeveloperCertificates`
/// and chain to an Apple root.
ProfileCms parseProfileCms(Uint8List bytes, String path) {
  try {
    final contentInfo = Der.single(
      bytes,
      DerTag.sequence,
      'mobileprovision ContentInfo',
    );
    final contentInfoReader = contentInfo.reader();
    final contentType = Der.oidValue(
      contentInfoReader.read(
        DerTag.objectIdentifier,
        'mobileprovision content type',
      ),
    );
    if (contentType != Oid.signedData) {
      throw FormatException('expected SignedData, found $contentType');
    }
    final explicitSignedData = contentInfoReader.read(
      DerTag.context0,
      'mobileprovision SignedData',
    );
    contentInfoReader.requireDone('mobileprovision ContentInfo');
    final signedData = Der.single(
      explicitSignedData.value,
      DerTag.sequence,
      'mobileprovision SignedData',
    );
    final signedDataReader = signedData.reader();
    signedDataReader.read(DerTag.integer, 'SignedData version');
    signedDataReader.read(DerTag.set, 'SignedData digest algorithms');
    final plist = _readEncapsulatedPlist(signedDataReader);
    final certificates = _readTrailingFields(signedDataReader);
    return (plist: Uint8List.fromList(plist), certificates: certificates);
  } on Object catch (error) {
    throw AppleError('Malformed mobileprovision CMS "$path": $error');
  }
}

/// Reads `encapContentInfo`, which must wrap the profile plist as an id-data
/// OCTET STRING inside an explicit [0].
Uint8List _readEncapsulatedPlist(DerReader signedDataReader) {
  final encapsulatedContentInfo = signedDataReader.read(
    DerTag.sequence,
    'encapsulated profile',
  );
  final encapsulatedReader = encapsulatedContentInfo.reader();
  final encapsulatedType = Der.oidValue(
    encapsulatedReader.read(
      DerTag.objectIdentifier,
      'encapsulated content type',
    ),
  );
  if (encapsulatedType != Oid.data) {
    throw FormatException(
      'expected encapsulated data, found $encapsulatedType',
    );
  }
  final explicitContent = encapsulatedReader.read(
    DerTag.context0,
    'encapsulated profile content',
  );
  encapsulatedReader.requireDone('encapsulated profile');
  final plist = Der.single(
    explicitContent.value,
    DerTag.octetString,
    'encapsulated profile plist',
  ).value;
  if (plist.isEmpty) {
    throw const FormatException('encapsulated profile plist is empty');
  }
  return plist;
}

/// Reads the optional `[0]` certificates, optional `[1]` revocation data, and
/// the terminal `SET OF SignerInfo`, rejecting anything else or anything
/// following the signer infos.
List<Uint8List> _readTrailingFields(DerReader signedDataReader) {
  final certificates = <Uint8List>[];
  var foundSignerInfos = false;
  while (!signedDataReader.isDone) {
    switch (signedDataReader.peekTag()) {
      case DerTag.context0:
        if (certificates.isNotEmpty) {
          throw const FormatException('duplicate certificate set');
        }
        final certificateSet = signedDataReader.read(
          DerTag.context0,
          'profile certificate set',
        );
        final certificateReader = certificateSet.reader();
        while (!certificateReader.isDone) {
          final embedded = certificateReader.read(
            DerTag.sequence,
            'embedded profile certificate',
          );
          _validateCertificateShape(embedded);
          certificates.add(Uint8List.fromList(embedded.encoded));
        }
      case DerTag.context1:
        signedDataReader.read(DerTag.context1, 'SignedData revocation data');
      case DerTag.set:
        signedDataReader.read(DerTag.set, 'SignedData signer infos');
        foundSignerInfos = true;
        if (!signedDataReader.isDone) {
          throw const FormatException('data follows SignedData signer infos');
        }
      case final tag:
        throw FormatException(
          'unexpected SignedData field 0x${tag.toRadixString(16)}',
        );
    }
  }
  if (!foundSignerInfos) {
    throw const FormatException('SignedData signer infos are missing');
  }
  return certificates;
}

void _validateCertificateShape(DerValue certificate) {
  final reader = certificate.reader();
  reader.read(DerTag.sequence, 'embedded TBSCertificate');
  reader.read(DerTag.sequence, 'embedded certificate algorithm');
  reader.read(DerTag.bitString, 'embedded certificate signature');
  reader.requireDone('embedded certificate');
}

Map<String, Object?> parsePlist(Uint8List bytes, String path) {
  try {
    return requiredMap(decodePropertyList(bytes), 'root property list', path);
  } on AppleError {
    rethrow;
  } on Object catch (error) {
    throw AppleError('Malformed provisioning plist in "$path": $error');
  }
}

Map<String, Object?> requiredMap(Object? value, String field, String path) {
  if (value is! Map<Object?, Object?>) {
    throw AppleError('Provisioning profile "$path" has an invalid $field map.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw AppleError(
        'Provisioning profile "$path" has a non-string key in $field.',
      );
    }
    result[entry.key! as String] = entry.value;
  }
  return result;
}

DateTime requiredDate(Map<String, Object?> profile, String key, String path) {
  final value = profile[key];
  if (value is! DateTime) {
    throw AppleError('Provisioning profile "$path" is missing valid $key.');
  }
  return value;
}

String requiredFirstString(
  Map<String, Object?> profile,
  String key,
  String path,
) {
  if (profile[key] case [final String first, ...] when first.isNotEmpty) {
    return first;
  }
  throw AppleError('Provisioning profile "$path" is missing $key.');
}

/// Reads `DeveloperCertificates`, which property list decoders surface as
/// either [ByteData] or [Uint8List] depending on the plist flavour.
List<Uint8List> developerCertificates(
  Map<String, Object?> profile,
  String path,
) {
  final value = profile['DeveloperCertificates'];
  if (value is! List<Object?> || value.isEmpty) {
    throw AppleError(
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
    throw AppleError(
      'Provisioning profile "$path" contains a malformed '
      'DeveloperCertificates entry.',
    );
  }).toList();
}
