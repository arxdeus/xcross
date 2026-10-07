import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/shared/signing/macho_format.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

/// Every `CS_` blob is big-endian, unlike the little-endian Mach-O container
/// that carries it.
@internal
const int csMagicRequirement = 0xFADE_0C00;
@internal
const int csMagicRequirements = 0xFADE_0C01;
@internal
const int csMagicCodeDirectory = 0xFADE_0C02;
@internal
const int csMagicEmbeddedSignature = 0xFADE_0CC0;
@internal
const int csMagicBlobWrapper = 0xFADE_0B01;
@internal
const int csMagicEmbeddedEntitlements = 0xFADE_7171;
@internal
const int csMagicEmbeddedDerEntitlements = 0xFADE_7172;

@internal
const int csslotCodeDirectory = 0;
@internal
const int csslotRequirements = 2;
@internal
const int csslotEntitlements = 5;
@internal
const int csslotDerEntitlements = 7;
@internal
const int csslotSignature = 0x10000;

/// `CS_EXECSEG_MAIN_BINARY`: set only on `MH_EXECUTE`.
@internal
const int csExecsegMainBinary = 0x1;

/// `CS_EXECSEG_ALLOW_UNSIGNED`: mirrors a `get-task-allow` entitlement.
@internal
const int csExecsegAllowUnsigned = 0x10;

/// Every `CS_` blob starts with a big-endian magic and total length.
@internal
const int csBlobHeaderLength = 8;

/// `CS_SuperBlob` header: magic, total length, and blob count.
@internal
const int csSuperBlobHeaderLength = 12;

/// One `CS_BlobIndex`: slot type and offset from the superblob start.
@internal
const int csBlobIndexLength = 8;

/// SHA-256 digest length, and therefore the size of every code directory slot.
@internal
const int csSha256Length = 32;

/// `CS_HASHTYPE_SHA256`.
@internal
const int csHashTypeSha256 = 2;

/// The `pageSize` field stores log2 of the hashed page size, not the size.
@internal
const int csPageSizeLog2 = 12;

/// `CS_SUPPORTSEXECSEG`: the lowest version that carries the exec-segment
/// fields this signer always writes.
@internal
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
@internal
const int designatedRequirementType = 3;

/// A requirement blob body starts with `kind`; 1 selects the expression form.
@internal
const int requirementExprForm = 1;

/// DER of OID 1.2.840.113635.100.6.2.1, Apple's "Worldwide Developer
/// Relations" intermediate-certificate marker extension.
@internal
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
  final teamOffset = CodeDirectoryField.size + identifierBytes.length;
  final specialSlotsOffset = teamOffset + teamBytes.length;
  _writeCodeDirectoryHeader(
    output,
    length: length,
    hashOffset: hashOffset,
    specialSlotCount: specialSlots.length,
    codeSlots: codeSlots,
    codeLimit: codeLimit,
    teamOffset: teamOffset,
    execSegmentLimit: execSegmentLimit,
    execSegmentFlags: execSegmentFlags,
  );
  output.setRange(CodeDirectoryField.size, teamOffset, identifierBytes);
  output.setRange(teamOffset, specialSlotsOffset, teamBytes);
  _writeSpecialSlots(output, specialSlotsOffset, specialSlots, path);
  _writeCodePageHashes(output, hashOffset, code, codeLimit, codeSlots);
  return output;
}

void _writeCodeDirectoryHeader(
  Uint8List output, {
  required int length,
  required int hashOffset,
  required int specialSlotCount,
  required int codeSlots,
  required int codeLimit,
  required int teamOffset,
  required int execSegmentLimit,
  required int execSegmentFlags,
}) {
  writeU32be(output, CodeDirectoryField.magic, csMagicCodeDirectory);
  writeU32be(output, CodeDirectoryField.length, length);
  writeU32be(output, CodeDirectoryField.version, codeDirectoryVersion);
  writeU32be(output, CodeDirectoryField.flags, 0);
  writeU32be(output, CodeDirectoryField.hashOffset, hashOffset);
  writeU32be(output, CodeDirectoryField.identOffset, CodeDirectoryField.size);
  writeU32be(output, CodeDirectoryField.nSpecialSlots, specialSlotCount);
  writeU32be(output, CodeDirectoryField.nCodeSlots, codeSlots);
  writeU32be(output, CodeDirectoryField.codeLimit, codeLimit);
  output[CodeDirectoryField.hashSize] = csSha256Length;
  output[CodeDirectoryField.hashType] = csHashTypeSha256;
  output[CodeDirectoryField.pageSize] = csPageSizeLog2;
  writeU32be(output, CodeDirectoryField.teamOffset, teamOffset);
  writeU64be(output, CodeDirectoryField.execSegBase, 0);
  writeU64be(output, CodeDirectoryField.execSegLimit, execSegmentLimit);
  writeU64be(output, CodeDirectoryField.execSegFlags, execSegmentFlags);
}

void _writeSpecialSlots(
  Uint8List output,
  int startOffset,
  List<Uint8List> specialSlots,
  String path,
) {
  var offset = startOffset;
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
}

void _writeCodePageHashes(
  Uint8List output,
  int hashOffset,
  Uint8List code,
  int codeLimit,
  int codeSlots,
) {
  // The final page is hashed short rather than zero-padded.
  for (var slot = 0; slot < codeSlots; slot++) {
    final start = slot * machoPageSize;
    final fullPageEnd = start + machoPageSize;
    final end = fullPageEnd < codeLimit ? fullPageEnd : codeLimit;
    final hash = sha256Digest(Uint8List.sublistView(code, start, end));
    output.setRange(
      hashOffset + slot * csSha256Length,
      hashOffset + (slot + 1) * csSha256Length,
      hash,
    );
  }
}

/// Builds the designated requirement, which in `codesign` syntax reads:
/// `identifier "<identifier>" and anchor apple generic and`
/// `certificate leaf[subject.CN] = "<subject>" and`
/// `certificate 1[field.1.2.840.113635.100.6.2.1] exists`.
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

@internal
void requireSigningString(String value, String field, String path) {
  if (value.isEmpty) machoFail(path, field, 'must not be empty');
  if (value.contains('\u0000')) machoFail(path, field, 'must not contain NUL');
}
