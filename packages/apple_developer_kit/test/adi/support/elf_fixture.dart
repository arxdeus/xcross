import 'dart:typed_data';
import 'package:meta/meta.dart';

@internal
Uint8List elfFixture(int machine, {int base = 0x1000}) {
  final bytes = Uint8List(0x3000);
  final data = ByteData.sublistView(bytes);
  void u16(int offset, int value) =>
      data.setUint16(offset, value, Endian.little);
  void u32(int offset, int value) =>
      data.setUint32(offset, value, Endian.little);
  void u64(int offset, int value) =>
      data.setUint64(offset, value, Endian.little);
  bytes.setAll(0, [0x7f, 69, 76, 70, 2, 1, 1]);
  u16(16, 3);
  u16(18, machine);
  u32(20, 1);
  u64(32, 64);
  u64(40, 0x200);
  u16(52, 64);
  u16(54, 56);
  u16(56, 2);
  u16(58, 64);
  u16(60, 4);
  u16(62, 2);
  for (var i = 0; i < 2; i++) {
    final ph = 64 + i * 56;
    u32(ph, 1);
    u32(ph + 4, i == 0 ? 5 : 6);
    u64(ph + 8, 0x1000 + i * 0x1000);
    u64(ph + 16, base + i * 0x1000);
    u64(ph + 32, 0x1000);
    u64(ph + 40, 0x1000);
    u64(ph + 48, 0x1000);
  }
  final names = '\u0000export\u0000external\u0000local\u0000'.codeUnits;
  bytes.setAll(0x500, names);
  for (var i = 1; i <= 3; i++) {
    final sh = 0x200 + i * 64;
    u32(sh + 4, [0, 11, 3, 4][i]);
    u64(sh + 24, [0, 0x400, 0x500, 0x600][i]);
    u64(sh + 32, [0, 96, names.length, 120][i]);
    if (i == 1) u32(sh + 40, 2);
  }
  for (var i = 1; i <= 3; i++) {
    final sym = 0x400 + i * 24;
    u32(sym, [0, 1, 8, 17][i]);
    bytes[sym + 4] = 0x11;
    u16(sym + 6, i == 2 ? 0 : 1);
    u64(sym + 8, i == 1 ? base + 0x1000 : (i == 3 ? base + 0x100 : 0));
  }
  final types = machine == 183 ? [1027, 257, 1025, 1026, 0] : [8, 1, 6, 7, 0];
  for (var i = 0; i < types.length; i++) {
    final rela = 0x600 + i * 24;
    u64(rela, base + 0x1000 + i * 8);
    u64(rela + 8, ([0, 3, 2, 2, 0][i] << 32) | types[i]);
    u64(rela + 16, [base + 0x1100, 3, 5, 7, 0][i]);
  }
  return bytes;
}
