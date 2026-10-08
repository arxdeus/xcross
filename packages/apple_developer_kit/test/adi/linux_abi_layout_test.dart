import 'dart:ffi';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/linux_abi.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

void main() {
  test('Linux x64 stat serialization retains every verified field offset', () {
    const layout = LinuxX64StatLayout();
    expect(layout.size, 144);
    using((arena) {
      final source = arena<Uint8>(56);
      ByteData.sublistView(source.asTypedList(56))
        ..setUint32(0, 1, Endian.little)
        ..setUint16(4, 2, Endian.little)
        ..setUint16(6, 0x8180, Endian.little)
        ..setInt16(8, 3, Endian.little)
        ..setInt16(10, 5, Endian.little)
        ..setInt16(12, 6, Endian.little)
        ..setUint32(16, 8, Endian.little)
        ..setInt64(24, -9, Endian.little)
        ..setInt64(32, -12, Endian.little)
        ..setInt64(40, -14, Endian.little)
        ..setInt64(48, -16, Endian.little);
      final output = arena<Uint8>(144);
      output.asTypedList(144).fillRange(0, 144, 0xa5);
      layout.write(output, source);
      final bytes = ByteData.sublistView(output.asTypedList(144));
      for (final entry in {0: 1, 8: 2, 16: 3, 40: 8}.entries) {
        expect(bytes.getUint64(entry.key, Endian.little), entry.value);
      }
      for (final entry in {24: 0x81ed, 28: 5, 32: 6, 36: 0}.entries) {
        expect(bytes.getUint32(entry.key, Endian.little), entry.value);
      }
      for (final entry in {
        48: -9,
        56: 4096,
        64: 0,
        72: -12,
        80: 0,
        88: -14,
        96: 0,
        104: -16,
        112: 0,
        120: 0,
        128: 0,
        136: 0,
      }.entries) {
        expect(bytes.getInt64(entry.key, Endian.little), entry.value);
      }
    });
  });

  test('LinuxTimeval retains two ordered signed 64-bit words', () {
    expect(sizeOf<LinuxTimeval>(), 16);
    using((arena) {
      final pointer = arena<LinuxTimeval>();
      pointer.ref
        ..tvSec = -123
        ..tvUsec = 456;
      final words = pointer.cast<Int64>();
      expect(words[0], -123);
      expect(words[1], 456);
    });
  });
}
