import 'dart:ffi';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/loader/internal/native_symbol_stubs_windows.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

void main() {
  test('LinuxStat retains the exact x64 field offsets and 144-byte layout', () {
    expect(sizeOf<LinuxStat>(), 144);
    using((arena) {
      final pointer = arena<LinuxStat>();
      pointer.ref
        ..stDev = 1
        ..stIno = 2
        ..stNlink = 3
        ..stMode = 4
        ..stUid = 5
        ..stGid = 6
        ..pad0 = 7
        ..stRdev = 8
        ..stSize = -9
        ..stBlksize = -10
        ..stBlocks = -11
        ..stAtime = -12
        ..stAtimensec = -13
        ..stMtime = -14
        ..stMtimensec = -15
        ..stCtime = -16
        ..stCtimensec = -17;
      for (var i = 0; i < 3; i++) {
        pointer.ref.unused[i] = -18 - i;
      }
      final bytes = ByteData.sublistView(
        pointer.cast<Uint8>().asTypedList(144),
      );
      for (final entry in {0: 1, 8: 2, 16: 3, 40: 8}.entries) {
        expect(bytes.getUint64(entry.key, Endian.host), entry.value);
      }
      for (final entry in {24: 4, 28: 5, 32: 6, 36: 7}.entries) {
        expect(bytes.getUint32(entry.key, Endian.host), entry.value);
      }
      for (var i = 0; i < 12; i++) {
        expect(bytes.getInt64(48 + i * 8, Endian.host), -9 - i);
      }
    });
  });

  test('LinuxTimeval retains two ordered signed native words', () {
    expect(sizeOf<LinuxTimeval>(), 2 * sizeOf<IntPtr>());
    using((arena) {
      final pointer = arena<LinuxTimeval>();
      pointer.ref
        ..tvSec = -123
        ..tvUsec = 456;
      final words = pointer.cast<IntPtr>();
      expect(words[0], -123);
      expect(words[1], 456);
    });
  });
}
