@TestOn('linux || mac-os')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/adi_architecture.dart';
import 'package:apple_developer_kit/src/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/adi/loader/internal/memory_allocator_posix.dart';
import 'package:apple_developer_kit/src/adi/loader/internal/sysv_abi_bridge.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'support/elf_fixture.dart';

Pointer<Void> symbol(String name) => using(
  (arena) => provision_posix_symbol(name.toNativeUtf8(allocator: arena).cast()),
);

void main() {
  test('native open translates create, exclusive, truncate and append', () {
    final directory = Directory.systemTemp.createTempSync('adi-shim-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final open = symbol('open')
        .cast<NativeFunction<Int32 Function(Pointer<Utf8>, Int32, Uint32)>>()
        .asFunction<int Function(Pointer<Utf8>, int, int)>();
    final close = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
    using((arena) {
      final path = '${directory.path}/file'.toNativeUtf8(allocator: arena);
      final fd = open(path, 0x40 | 0x80 | 2, 0x180);
      expect(fd, greaterThanOrEqualTo(0));
      close(fd);
      expect(open(path, 0x40 | 0x80 | 2, 0x180), -1);
      final file = File(path.toDartString())..writeAsStringSync('content');
      final truncated = open(path, 0x200 | 1, 0);
      expect(truncated, greaterThanOrEqualTo(0));
      close(truncated);
      expect(file.lengthSync(), 0);
      final append = open(path, 0x400 | 1, 0);
      expect(append, greaterThanOrEqualTo(0));
      final write = DynamicLibrary.process()
          .lookupFunction<
            IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
            int Function(int, Pointer<Uint8>, int)
          >('write');
      final payload = 'abc'.toNativeUtf8(allocator: arena);
      expect(write(append, payload.cast(), 3), 3);
      close(append);
      expect(file.readAsStringSync(), 'abc');
      final arm64 =
          AdiArchitecture.forAbi(Abi.current()) == AdiArchitecture.arm64;
      final directoryFlag = arm64 ? 1 << 14 : 1 << 16;
      final nofollowFlag = arm64 ? 1 << 15 : 1 << 17;
      expect(open(path, directoryFlag, 0), -1);
      final dirFd = open(
        directory.path.toNativeUtf8(allocator: arena),
        directoryFlag,
        0,
      );
      expect(dirFd, greaterThanOrEqualTo(0));
      close(dirFd);
      final link = Link('${directory.path}/link')..createSync(file.path);
      expect(
        open(link.path.toNativeUtf8(allocator: arena), nofollowFlag, 0),
        -1,
      );
    });
  });

  test('native stat and timeval write the Android layout without overruns', () {
    final directory = Directory.systemTemp.createTempSync('adi-stat-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/file')..writeAsStringSync('1234567');
    final lstat = symbol('lstat')
        .cast<NativeFunction<Int32 Function(Pointer<Utf8>, Pointer<Uint8>)>>()
        .asFunction<int Function(Pointer<Utf8>, Pointer<Uint8>)>();
    final gettimeofday = symbol('gettimeofday')
        .cast<NativeFunction<Int32 Function(Pointer<Int64>, Pointer<Void>)>>()
        .asFunction<int Function(Pointer<Int64>, Pointer<Void>)>();
    using((arena) {
      final out = arena<Uint8>(160);
      out.asTypedList(160).fillRange(0, 160, 0xa5);
      expect(lstat(file.path.toNativeUtf8(allocator: arena), out), 0);
      final data = ByteData.sublistView(out.asTypedList(160));
      expect(data.getInt64(48, Endian.little), 7);
      final size =
          AdiArchitecture.forAbi(Abi.current()) == AdiArchitecture.arm64
          ? 128
          : 144;
      expect(out.asTypedList(160).sublist(size), everyElement(0xa5));
      final time = arena<Int64>(3);
      time[2] = 0x123456;
      expect(gettimeofday(time, nullptr), 0);
      expect(time[0], greaterThan(1700000000));
      expect(time[1], inInclusiveRange(0, 999999));
      expect(time[2], 0x123456);
    });
  });

  test(
    'copied host machine code executes after instruction-cache synchronization',
    () {
      final architecture = AdiArchitecture.forAbi(Abi.current());
      final bytes = elfFixture(architecture.elfMachine);
      bytes.setAll(
        0x1100,
        architecture == AdiArchitecture.arm64
            ? [0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]
            : [0xb8, 42, 0, 0, 0, 0xc3],
      );
      final library = ElfLoadedLibrary.load(
        bytes,
        PosixMemoryAllocator(),
        (_) => nullptr,
      );
      final call = library
          .lookup('local')
          .cast<NativeFunction<Int32 Function()>>()
          .asFunction<int Function()>();
      expect(call(), 42);
    },
  );
}
