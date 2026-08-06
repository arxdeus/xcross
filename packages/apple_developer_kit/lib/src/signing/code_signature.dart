import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/signing/bytes.dart';
import 'package:apple_developer_kit/src/signing/der.dart';
import 'package:apple_developer_kit/src/signing/macho_format.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';

/// Every `CS_` blob is big-endian, unlike the little-endian Mach-O container
/// that carries it.
const int csMagicRequirement = 0xFADE_0C00;
const int csMagicRequirements = 0xFADE_0C01;
const int csMagicCodeDirectory = 0xFADE_0C02;
const int csMagicEmbeddedSignature = 0xFADE_0CC0;
const int csMagicBlobWrapper = 0xFADE_0B01;
const int csMagicEmbeddedEntitlements = 0xFADE_7171;
const int csMagicEmbeddedDerEntitlements = 0xFADE_7172;

const int csslotCodeDirectory = 0;
const int csslotRequirements = 2;
const int csslotEntitlements = 5;
const int csslotDerEntitlements = 7;
const int csslotSignature = 0x10000;

/// `CS_EXECSEG_MAIN_BINARY`: set only on `MH_EXECUTE`.
const int csExecsegMainBinary = 0x1;

/// `CS_EXECSEG_ALLOW_UNSIGNED`: mirrors a `get-task-allow` entitlement.
const int csExecsegAllowUnsigned = 0x10;

/// Every `CS_` blob starts with a big-endian magic and total length.
const int csBlobHeaderLength = 8;

/// `CS_SuperBlob` header: magic, total length, and blob count.
const int csSuperBlobHeaderLength = 12;

/// One `CS_BlobIndex`: slot type and offset from the superblob start.
const int csBlobIndexLength = 8;

/// SHA-256 digest length, and therefore the size of every code directory slot.
const int csSha256Length = 32;

/// `CS_HASHTYPE_SHA256`.
const int csHashTypeSha256 = 2;

/// The `pageSize` field stores log2 of the hashed page size, not the size.
const int csPageSizeLog2 = 12;

/// `CS_SUPPORTSEXECSEG`: the lowest version that carries the exec-segment
/// fields this signer always writes.
const int codeDirectoryVersion = 0x20400;

/// `CS_CodeDirectory` field offsets, in the `0x20400` layout.
@internal
abstract final class CodeDirectoryField {
  static const int magic = 0;
  static const int length = 4;
  static const int version = 8;
  static const int flags = 12;
  static const int hashOffset = 16;
  static const int identOffset = 20;
  static const int nSpecialSlots = 24;
  static const int nCodeSlots = 28;
  static const int codeLimit = 32;
  static const int hashSize = 36;
  static const int hashType = 37;
  static const int platform = 38;
  static const int pageSize = 39;
  static const int teamOffset = 48;
  static const int execSegBase = 64;
  static const int execSegLimit = 72;
  static const int execSegFlags = 80;

  /// Header size, and therefore the offset of the identifier string.
  static const int size = 88;
}

/// `kSecDesignatedRequirementType`, the only requirement this signer emits.
const int designatedRequirementType = 3;

/// A requirement blob body starts with `kind`; 1 selects the expression form.
const int requirementExprForm = 1;

/// DER of OID 1.2.840.113635.100.6.2.1, Apple's "Worldwide Developer
/// Relations" intermediate-certificate marker extension.
const List<int> appleWwdrMarkerOid = [
  0x2a,
  0x86,
  0x48,
  0x86,
  0xf7,
  0x63,
  0x64,
  0x06,
  0x02,
  0x01,
];

/// One entry of a `CS_SuperBlob`.
@internal
@immutable
final class SignatureSlot {
  const SignatureSlot({required this.type, required this.bytes});

  final int type;
  final Uint8List bytes;
}

@internal
@useResult
Uint8List sha256Digest(List<int> bytes) =>
    Uint8List.fromList(crypto.sha256.convert(bytes).bytes);

@internal
@useResult
Uint8List be32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

@internal
void writeU32be(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint32(offset, value);

@internal
void writeU64be(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint64(offset, value);

/// Wraps [body] in a `CS_` blob header carrying [magic] and the total length.
@internal
@useResult
Uint8List csBlob(int magic, Iterable<int> body, String path, String field) {
  final bytes = body is Uint8List ? body : Uint8List.fromList(body.toList());
  final length = checkedAdd(
    csBlobHeaderLength,
    bytes.length,
    uint32Max,
    path,
    '$field length',
  );
  return Uint8List.fromList([...be32(magic), ...be32(length), ...bytes]);
}

/// Lays out a `CS_SuperBlob`: header, one index entry per slot, then the slot
/// payloads back to back in the same order.
@internal
@useResult
Uint8List buildSuperblob(List<SignatureSlot> slots, String path) {
  final headerLength = checkedAdd(
    csSuperBlobHeaderLength,
    slots.length * csBlobIndexLength,
    uint32Max,
    path,
    'SuperBlob header length',
  );
  var length = headerLength;
  for (final slot in slots) {
    length = checkedAdd(
      length,
      slot.bytes.length,
      uint32Max,
      path,
      'SuperBlob length',
    );
  }
  final output = Uint8List(length);
  writeU32be(output, 0, csMagicEmbeddedSignature);
  writeU32be(output, 4, length);
  writeU32be(output, 8, slots.length);
  var offset = headerLength;
  for (var index = 0; index < slots.length; index++) {
    writeU32be(
      output,
      csSuperBlobHeaderLength + index * csBlobIndexLength,
      slots[index].type,
    );
    writeU32be(
      output,
      csSuperBlobHeaderLength + 4 + index * csBlobIndexLength,
      offset,
    );
    output.setRange(
      offset,
      offset + slots[index].bytes.length,
      slots[index].bytes,
    );
    offset += slots[index].bytes.length;
  }
  return output;
}

/// Builds the `CS_CodeDirectory`: the header, the NUL-terminated identifier
/// and team strings, the special slots, and one SHA-256 per code page.
///
/// [specialSlots] is stored in DESCENDING slot order immediately BEFORE
/// `hashOffset`, so the negative slot -N lands at `hashOffset - N * 32`. The
/// caller therefore passes them as
/// `[DER(-7), spare(-6), entitlements(-5), spare(-4), resources(-3),
/// requirements(-2), Info.plist(-1)]`.
@internal
@useResult
Uint8List buildCodeDirectory({
  required Uint8List code,
  required int codeLimit,
  required int execSegmentLimit,
  required int execSegmentFlags,
  required String identifier,
  required String teamIdentifier,
  required List<Uint8List> specialSlots,
  required String path,
}) {
  final identifierBytes = Uint8List.fromList([...utf8.encode(identifier), 0]);
  final teamBytes = Uint8List.fromList([...utf8.encode(teamIdentifier), 0]);
  final codeSlots = (codeLimit + machoPageSize - 1) ~/ machoPageSize;
  final hashOffset = checkedAdd(
    CodeDirectoryField.size + identifierBytes.length + teamBytes.length,
    specialSlots.length * csSha256Length,
    uint32Max,
    path,
    'CodeDirectory.hashOffset',
  );
  final length = checkedAdd(
    hashOffset,
    codeSlots * csSha256Length,
    uint32Max,
    path,
    'CodeDirectory.length',
  );
  final output = Uint8List(length);
  writeU32be(output, CodeDirectoryField.magic, csMagicCodeDirectory);
  writeU32be(output, CodeDirectoryField.length, length);
  writeU32be(output, CodeDirectoryField.version, codeDirectoryVersion);
  writeU32be(output, CodeDirectoryField.flags, 0);
  writeU32be(output, CodeDirectoryField.hashOffset, hashOffset);
  writeU32be(output, CodeDirectoryField.identOffset, CodeDirectoryField.size);
  writeU32be(output, CodeDirectoryField.nSpecialSlots, specialSlots.length);
  writeU32be(output, CodeDirectoryField.nCodeSlots, codeSlots);
  writeU32be(output, CodeDirectoryField.codeLimit, codeLimit);
  output[CodeDirectoryField.hashSize] = csSha256Length;
  output[CodeDirectoryField.hashType] = csHashTypeSha256;
  output[CodeDirectoryField.pageSize] = csPageSizeLog2;
  writeU32be(
    output,
    CodeDirectoryField.teamOffset,
    CodeDirectoryField.size + identifierBytes.length,
  );
  writeU64be(output, CodeDirectoryField.execSegBase, 0);
  writeU64be(output, CodeDirectoryField.execSegLimit, execSegmentLimit);
  writeU64be(output, CodeDirectoryField.execSegFlags, execSegmentFlags);
  output.setRange(
    CodeDirectoryField.size,
    CodeDirectoryField.size + identifierBytes.length,
    identifierBytes,
  );
  output.setRange(
    CodeDirectoryField.size + identifierBytes.length,
    CodeDirectoryField.size + identifierBytes.length + teamBytes.length,
    teamBytes,
  );
  var offset =
      CodeDirectoryField.size + identifierBytes.length + teamBytes.length;
  for (final hash in specialSlots) {
    if (hash.length != csSha256Length) {
      machoFail(
        path,
        'CodeDirectory special slot',
        'SHA-256 hash is not 32 bytes',
      );
    }
    output.setRange(offset, offset + csSha256Length, hash);
    offset += csSha256Length;
  }
  // The final page is hashed short rather than zero-padded.
  for (var slot = 0; slot < codeSlots; slot++) {
    final start = slot * machoPageSize;
    final end = start + machoPageSize < codeLimit
        ? start + machoPageSize
        : codeLimit;
    final hash = sha256Digest(Uint8List.sublistView(code, start, end));
    output.setRange(
      hashOffset + slot * csSha256Length,
      hashOffset + (slot + 1) * csSha256Length,
      hash,
    );
  }
  return output;
}

/// Builds the designated requirement, which in `codesign` syntax reads:
/// identifier "<identifier>" and anchor apple generic and
/// certificate leaf[subject.CN] = "<subject>" and
/// certificate 1[field.1.2.840.113635.100.6.2.1] exists.
///
/// The blob is a `CS_Requirements` superblob holding exactly one
/// `CS_Requirement`, whose index entry sits at offset 20 (12-byte header plus
/// one 8-byte index).
@internal
@useResult
Uint8List buildRequirements(String identifier, String subject, String path) {
  requireSigningString(subject, 'certificate common name', path);
  final expression = BytesBuilder(copy: false)
    ..add(be32(requirementExprForm))
    ..add(be32(6))
    ..add(be32(2))
    ..add(_padded(identifier))
    ..add(be32(6))
    ..add(be32(15))
    ..add(be32(6))
    ..add(be32(11))
    ..add(be32(0))
    ..add(_padded('subject.CN'))
    ..add(be32(1))
    ..add(_padded(subject))
    ..add(be32(14))
    ..add(be32(1))
    ..add(_paddedBytes(appleWwdrMarkerOid))
    ..add(be32(0));
  final expressionBytes = expression.takeBytes();
  final innerLength = csBlobHeaderLength + expressionBytes.length;
  const indexLength = csSuperBlobHeaderLength + csBlobIndexLength;
  final totalLength = indexLength + innerLength;
  if (totalLength > uint32Max) {
    machoFail(path, 'designated requirement length', 'exceeds 32 bits');
  }
  return Uint8List.fromList([
    ...be32(csMagicRequirements),
    ...be32(totalLength),
    ...be32(1),
    ...be32(designatedRequirementType),
    ...be32(indexLength),
    ...be32(csMagicRequirement),
    ...be32(innerLength),
    ...expressionBytes,
  ]);
}

/// Requirement operands are length-prefixed and padded to a 4-byte boundary.
Uint8List _padded(String value) => _paddedBytes(utf8.encode(value));

Uint8List _paddedBytes(List<int> value) => Uint8List.fromList([
  ...be32(value.length),
  ...value,
  ...List<int>.filled((4 - value.length % 4) % 4, 0),
]);

/// True when the entitlements grant `get-task-allow`, which the exec segment
/// must mirror with `CS_EXECSEG_ALLOW_UNSIGNED`.
@internal
@useResult
bool entitlementsAllowUnsigned(Uint8List xmlEntitlements) {
  final xml = utf8.decode(xmlEntitlements.sublist(csBlobHeaderLength));
  return RegExp(r'<key>get-task-allow</key>\s*<true\s*/>').hasMatch(xml);
}

/// Serializes [entitlements] as an XML plist inside a `CS_` blob.
@internal
@useResult
Uint8List buildEntitlementsXml(Map<String, Object?> entitlements, String path) {
  final normalized = _normalizePlist(entitlements, path, 'XML entitlements');
  try {
    final xml = PropertyListSerialization.stringWithPropertyList(normalized);
    return csBlob(
      csMagicEmbeddedEntitlements,
      utf8.encode(xml),
      path,
      'XML entitlements',
    );
  } on AppleError {
    rethrow;
  } on Object catch (error) {
    machoFail(path, 'XML entitlements', '$error');
  }
}

/// Rebuilds the plist with UTF-8-sorted keys so the XML is byte-deterministic
/// regardless of the caller's map iteration order.
Object _normalizePlist(Object? value, String path, String field) {
  if (value is bool || value is int || value is String || value is DateTime) {
    return value!;
  }
  if (value is Uint8List) return ByteData.sublistView(value);
  if (value is ByteData) {
    return ByteData.sublistView(
      Uint8List.fromList(
        value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes),
      ),
    );
  }
  if (value is List<Object?>) {
    return [
      for (var index = 0; index < value.length; index++)
        _normalizePlist(value[index], path, '$field[$index]'),
    ];
  }
  if (value is Map<Object?, Object?>) {
    final result = SplayTreeMap<String, Object?>(compareUtf8);
    for (final entry in value.entries) {
      if (entry.key is! String) {
        machoFail(path, field, 'contains a non-string map key');
      }
      final key = entry.key! as String;
      result[key] = _normalizePlist(entry.value, path, '$field.$key');
    }
    return result;
  }
  machoFail(path, field, 'unsupported value type ${value.runtimeType}');
}

/// Serializes [entitlements] as Apple's DER entitlements blob: version 1
/// followed by the dictionary, all wrapped in `[APPLICATION 16]`.
@internal
@useResult
Uint8List buildDerEntitlements(Map<String, Object?> entitlements, String path) {
  final dictionary = _derValue(entitlements, path, 'DER entitlements');
  final body = Uint8List.fromList([
    ...Der.tlv(DerTag.integer, const [1]),
    ...dictionary,
  ]);
  final raw = Der.tlv(DerTag.application16, body);
  return csBlob(csMagicEmbeddedDerEntitlements, raw, path, 'DER entitlements');
}

/// Encodes one entitlement value. Dictionaries become `[16]`-tagged sequences
/// of key/value pairs, sorted by the UTF-8 bytes of the key.
Uint8List _derValue(Object? value, String path, String field) {
  if (value is bool) {
    return Uint8List.fromList([DerTag.boolean, 1, if (value) 0xff else 0]);
  }
  if (value is int) return _derInteger(value, path, field);
  if (value is String) return Der.tlv(DerTag.utf8String, utf8.encode(value));
  if (value is Uint8List) return Der.tlv(DerTag.octetString, value);
  if (value is ByteData) {
    return Der.tlv(
      DerTag.octetString,
      value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes),
    );
  }
  if (value is DateTime) {
    final utc = value.toUtc();
    if (utc.year < 0 || utc.year > 9999) {
      machoFail(path, field, 'date year is outside canonical GeneralizedTime');
    }
    String two(int part) => part.toString().padLeft(2, '0');
    final text =
        '${utc.year.toString().padLeft(4, '0')}'
        '${two(utc.month)}${two(utc.day)}${two(utc.hour)}'
        '${two(utc.minute)}${two(utc.second)}Z';
    return Der.tlv(DerTag.generalizedTime, ascii.encode(text));
  }
  if (value is List<Object?>) {
    return Der.tlv(DerTag.sequence, [
      for (var index = 0; index < value.length; index++)
        ..._derValue(value[index], path, '$field[$index]'),
    ]);
  }
  if (value is Map<Object?, Object?>) {
    final entries = <({Uint8List key, Object? value})>[];
    for (final entry in value.entries) {
      if (entry.key is! String) {
        machoFail(path, field, 'contains a non-string map key');
      }
      entries.add((
        key: Uint8List.fromList(utf8.encode(entry.key! as String)),
        value: entry.value,
      ));
    }
    entries.sort((left, right) => compareBytes(left.key, right.key));
    return Der.tlv(DerTag.context16, [
      for (final entry in entries)
        ...Der.tlv(DerTag.sequence, [
          ...Der.tlv(DerTag.utf8String, entry.key),
          ..._derValue(entry.value, path, '$field.${utf8.decode(entry.key)}'),
        ]),
    ]);
  }
  machoFail(path, field, 'unsupported value type ${value.runtimeType}');
}

/// Encodes a plist integer as a minimal signed 64-bit two's-complement
/// `INTEGER`. Unlike [Der.unsignedInteger] this must also express negatives,
/// so it trims redundant leading `0x00`/`0xff` octets by hand.
Uint8List _derInteger(int value, String path, String field) {
  const minimum = -0x8000_0000_0000_0000;
  const maximum = 0x7FFF_FFFF_FFFF_FFFF;
  if (value < minimum || value > maximum) {
    machoFail(path, field, 'integer is outside the signed 64-bit plist range');
  }
  final bytes = Uint8List(8);
  var current = value;
  for (var index = 7; index >= 0; index--) {
    bytes[index] = current & 0xff;
    current >>= 8;
  }
  var start = 0;
  while (start < 7 &&
      ((bytes[start] == 0 && bytes[start + 1] & 0x80 == 0) ||
          (bytes[start] == 0xff && bytes[start + 1] & 0x80 != 0))) {
    start++;
  }
  return Der.tlv(DerTag.integer, Uint8List.sublistView(bytes, start));
}

@internal
void requireSigningString(String value, String field, String path) {
  if (value.isEmpty) machoFail(path, field, 'must not be empty');
  if (value.contains('\u0000')) machoFail(path, field, 'must not contain NUL');
}
