import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/signing/internal/macho_command_scan.dart';
import 'package:apple_developer_kit/src/signing/internal/macho_header.dart';
import 'package:meta/meta.dart';

/// Largest value any 32-bit Mach-O field can hold.
const int uint32Max = 0xFFFF_FFFF;

/// Mach-O page-hash and segment alignment granularity on arm64.
const int machoPageSize = 4096;

/// `LC_CODE_SIGNATURE.dataoff` and `datasize` are both 16-byte aligned.
const int signatureAlignment = 16;

const int fatMagic = 0xCAFE_BABE;
const int fatCigam = 0xBEBA_FECA;
const int mhMagic = 0xFEED_FACE;
const int mhCigam = 0xCEFA_EDFE;
const int mhMagic64 = 0xFEED_FACF;
const int mhCigam64 = 0xCFFA_EDFE;

const int cpuTypeArm64 = 0x0100_000C;

/// `MH_EXECUTE`: only main executables carry entitlements and exec-seg flags.
const int mhExecute = 2;

const int lcSegment = 0x1;
const int lcSegment64 = 0x19;
const int lcCodeSignature = 0x1d;
const int lcEncryptionInfo = 0x21;
const int lcEncryptionInfo64 = 0x2c;

const String textSegmentName = '__TEXT';
const String linkeditSegmentName = '__LINKEDIT';
const String textSectionName = '__text';

/// `mach_header_64` field offsets from `<mach-o/loader.h>`.
@internal
abstract final class MachHeader64 {
  static const int magic = 0;
  static const int cpuType = 4;
  static const int fileType = 12;
  static const int ncmds = 16;
  static const int sizeofcmds = 20;

  /// Header size, and therefore the offset of the first load command.
  static const int size = 32;
}

/// `load_command` field offsets shared by every command.
@internal
abstract final class LoadCommand {
  static const int cmd = 0;
  static const int cmdsize = 4;

  /// Bytes that must be readable before `cmdsize` can be trusted.
  static const int size = 8;
}

/// `segment_command_64` field offsets.
@internal
abstract final class SegmentCommand64 {
  static const int segname = 8;
  static const int vmsize = 32;
  static const int fileoff = 40;
  static const int filesize = 48;
  static const int nsects = 64;

  /// Command size without sections, and the offset of the first `section_64`.
  static const int size = 72;
}

/// `section_64` field offsets and array stride.
@internal
abstract final class Section64 {
  static const int sectname = 0;
  static const int size = 40;
  static const int offset = 48;
  static const int flags = 64;
  static const int stride = 80;
}

/// `LC_CODE_SIGNATURE` field offsets. The command is always 16 bytes.
@internal
abstract final class CodeSignatureCommand {
  static const int dataOffset = 8;
  static const int dataSize = 12;
  static const int size = 16;
}

/// Section types whose contents are not file-backed, so their `offset` must
/// not be treated as a file range (`<mach-o/loader.h>` section flags).
const int sZerofill = 0x1;
const int sGbZerofill = 0x0c;
const int sThreadLocalZerofill = 0x12;

/// Length of a fixed 16-byte `char[16]` name field.
const int nameFieldLength = 16;

/// Byte lengths of `encryption_info_command` and its 64-bit variant.
const int encryptionInfoSize = 20;
const int encryptionInfo64Size = 24;

/// Offset of `cryptid` within either encryption command.
const int encryptionCryptIdOffset = 16;

@internal
Never machoFail(String path, String field, String reason) =>
    throw AppleError('Mach-O "$path" has invalid $field: $reason.');

void requireRange(
  Uint8List bytes,
  int offset,
  int length,
  String path,
  String field,
) {
  if (offset < 0 || length < 0 || offset > bytes.length - length) {
    machoFail(path, field, 'range is outside the file');
  }
}

@internal
@useResult
int readU32le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

@internal
@useResult
int readU64le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint64(offset, Endian.little);

void writeU32le(
  Uint8List bytes,
  int offset,
  int value,
  String path,
  String field,
) {
  if (value < 0 || value > uint32Max) machoFail(path, field, 'exceeds 32 bits');
  requireRange(bytes, offset, 4, path, field);
  ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);
}

void writeU64le(
  Uint8List bytes,
  int offset,
  int value,
  String path,
  String field,
) {
  if (value < 0) machoFail(path, field, 'must not be negative');
  requireRange(bytes, offset, 8, path, field);
  ByteData.sublistView(bytes).setUint64(offset, value, Endian.little);
}

/// Reads a NUL-padded ASCII `char[length]` field such as `segname`.
@internal
@useResult
String readFixedString(
  Uint8List bytes,
  int offset,
  int length,
  String path,
  String field,
) {
  requireRange(bytes, offset, length, path, field);
  final fieldBytes = Uint8List.sublistView(bytes, offset, offset + length);
  final nul = fieldBytes.indexOf(0);
  try {
    return ascii.decode(nul < 0 ? fieldBytes : fieldBytes.sublist(0, nul));
  } on FormatException {
    machoFail(path, field, 'is not ASCII');
  }
}

@internal
@useResult
int checkedAdd(int left, int right, int maximum, String path, String field) {
  if (left < 0 || right < 0 || left > maximum - right) {
    machoFail(path, field, 'integer overflow or out-of-bounds range');
  }
  return left + right;
}

@internal
@useResult
int checkedMultiply(
  int left,
  int right,
  int maximum,
  String path,
  String field,
) {
  if (left < 0 || right < 0 || (left != 0 && right > maximum ~/ left)) {
    machoFail(path, field, 'integer overflow');
  }
  return left * right;
}

@internal
@useResult
int alignUp(int value, int alignment, String path, String field) {
  final remainder = value % alignment;
  return remainder == 0
      ? value
      : checkedAdd(value, alignment - remainder, uint32Max, path, field);
}

/// The validated subset of a thin arm64 Mach-O that signing needs.
///
/// Parsing is deliberately strict: anything the signer cannot rewrite safely
/// (fat binaries, 32-bit or big-endian files, encrypted binaries, a
/// non-terminal `__LINKEDIT`) is rejected up front rather than mis-signed.
@internal
@immutable
class MachOLayout {
  const MachOLayout({
    required this.fileType,
    required this.ncmds,
    required this.sizeofcmds,
    required this.commandsEnd,
    required this.commandSlack,
    required this.textVmSize,
    required this.originalLength,
    required this.linkeditCommand,
    required this.linkeditFileOffset,
    required this.linkeditVmSize,
    required this.signatureCommand,
    required this.signatureDataOffset,
    required this.signatureDataSize,
  });

  factory MachOLayout.parse(Uint8List bytes, String path) {
    final header = MachOHeader.read(bytes, path);
    final scan = MachOCommandScan.walk(bytes, path, header);
    return scan.toLayout(bytes, path, header);
  }

  final int fileType;
  final int ncmds;
  final int sizeofcmds;
  final int commandsEnd;

  /// Zero bytes available between the last load command and the first
  /// file-backed section, where a new `LC_CODE_SIGNATURE` can be injected.
  final int commandSlack;
  final int textVmSize;
  final int originalLength;
  final int linkeditCommand;
  final int linkeditFileOffset;
  final int linkeditVmSize;
  final int? signatureCommand;
  final int signatureDataOffset;
  final int signatureDataSize;
}
