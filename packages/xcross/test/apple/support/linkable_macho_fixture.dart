import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A minimal thin arm64 `MH_EXECUTE` with `__TEXT`, `__LINKEDIT` and load
/// command slack, unsigned: the shape the in-process signer lays out.
@internal
Uint8List linkableMachO() {
  const sizeofcmds = 152 + 72;
  const textOffset = 32 + sizeofcmds + 16;
  const linkedit = 4096;
  final bytes = Uint8List(linkedit);
  final data = ByteData.sublistView(bytes);
  void u32(int offset, int value) =>
      data.setUint32(offset, value, Endian.little);
  void u64(int offset, int value) =>
      data.setUint64(offset, value, Endian.little);
  void name(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, ascii.encode(value));
  u32(0, 0xfeedfacf);
  u32(4, 0x0100000c);
  u32(12, 2);
  u32(16, 2);
  u32(20, sizeofcmds);
  var command = 32;
  u32(command, 0x19);
  u32(command + 4, 152);
  name(command + 8, '__TEXT');
  u64(command + 32, linkedit);
  u64(command + 48, linkedit);
  u32(command + 56, 7);
  u32(command + 60, 5);
  u32(command + 64, 1);
  final section = command + 72;
  name(section, '__text');
  name(section + 16, '__TEXT');
  u64(section + 32, textOffset);
  u64(section + 40, 16);
  u32(section + 48, textOffset);
  u32(section + 52, 2);
  u32(section + 64, 0x80000400);
  for (var index = 0; index < 16; index++) {
    bytes[textOffset + index] = index + 1;
  }
  command += 152;
  u32(command, 0x19);
  u32(command + 4, 72);
  name(command + 8, '__LINKEDIT');
  u64(command + 24, linkedit);
  u64(command + 40, linkedit);
  u32(command + 56, 7);
  u32(command + 60, 1);
  return bytes;
}
