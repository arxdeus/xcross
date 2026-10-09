import 'dart:ffi';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_code_preparation.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/linux_abi.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/windows_adi_abi.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/windows_arm64_code_preparation.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/windows_crt.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/loader_windows.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'support/elf_fixture.dart';

void main() {
  test('dlopen paths drop the extended-length prefix ADI builds', () {
    // Seen from the real libstoreservicescore.so on Windows ARM64: it joins
    // the library directory into `//?/C:/...`, which Win32 rejects as a
    // relative path with ERROR_INVALID_NAME.
    expect(
      windowsDlopenPath('//?/C:/Users/Me/.cache/arm64-v8a/libCoreADI.so'),
      r'C:\Users\Me\.cache\arm64-v8a\libCoreADI.so',
    );
    expect(
      windowsDlopenPath('C:/Users/Me/arm64-v8a/libCoreADI.so'),
      r'C:\Users\Me\arm64-v8a\libCoreADI.so',
    );
    expect(windowsDlopenPath('libCoreADI.so'), 'libCoreADI.so');
  });

  test('Windows policy owns the matching executable code adapter', () {
    expect(
      WindowsAdiAbi.forAbi(Abi.windowsX64).codePreparation,
      isA<UnmodifiedElfCodePreparation>(),
    );
    expect(
      WindowsAdiAbi.forAbi(Abi.windowsArm64).codePreparation,
      isA<WindowsArm64CodePreparation>(),
    );
  });

  test('ARM64 code adapter rejects invalid ranges before native calls', () {
    const preparation = WindowsArm64CodePreparation();
    for (final (address, length) in [(0, 4), (1, 4), (4, 0), (4, -4), (4, 3)]) {
      expect(
        () => preparation.prepare(Pointer<Uint8>.fromAddress(address), length),
        throwsArgumentError,
      );
    }
  });

  for (final (host, machine, size, mode, links, uid, gid, rdev) in [
    (Abi.windowsX64, 62, 144, 24, 16, 28, 32, 40),
    (Abi.windowsArm64, 183, 128, 16, 20, 24, 28, 32),
  ]) {
    test('$host selects and validates the matching ELF machine', () {
      final abi = WindowsAdiAbi.forAbi(host);
      expect(abi.architecture.elfMachine, machine);
      expect(() => abi.validateElf(elfFixture(machine)), returnsNormally);
      for (final other in [0, 3, 40, if (machine == 62) 183 else 62]) {
        expect(() => abi.validateElf(elfFixture(other)), throwsFormatException);
      }
    });

    test('$host rejects unsupported ELF TLS segments', () {
      final bytes = elfFixture(machine);
      final data = ByteData.sublistView(bytes);
      final phoff = data.getUint64(32, Endian.little);
      data.setUint32(phoff, 7, Endian.little);
      expect(
        () => WindowsAdiAbi.forAbi(host).validateElf(bytes),
        throwsUnsupportedError,
      );
    });

    for (final (name, offset, value) in [
      ('unallocated code', 0x308, 4),
      ('mismatched file offset', 0x318, 0x1104),
      ('code in bss', 0x310, 0x2800),
      ('overlapping allocated data', 0x390, 0x1108),
    ]) {
      test('$host rejects $name before native initialization', () {
        final abi = WindowsAdiAbi.forAbi(host);
        final bytes = elfFixture(machine);
        expect(() => abi.validateElf(bytes), returnsNormally);
        ByteData.sublistView(bytes).setUint64(offset, value, Endian.little);
        expect(() => abi.validateElf(bytes), throwsFormatException);
      });
    }

    test('$host writes every stat field and preserves adjacent memory', () {
      final layout = WindowsAdiAbi.forAbi(host).statLayout;
      expect(layout.size, size);
      final source = calloc<Uint8>(56);
      final allocation = calloc<Uint8>(size + 32);
      addTearDown(() {
        calloc.free(source);
        calloc.free(allocation);
      });
      allocation.asTypedList(size + 32).fillRange(0, size + 32, 0xa5);
      final input = ByteData.sublistView(source.asTypedList(56));
      input
        ..setUint32(0, 0xfedcba98, Endian.little)
        ..setUint16(4, 0xabcd, Endian.little)
        ..setUint16(6, 0x8180, Endian.little)
        ..setInt16(8, 0x1234, Endian.little)
        ..setInt16(10, 123, Endian.little)
        ..setInt16(12, 456, Endian.little)
        ..setUint32(16, 0x87654321, Endian.little)
        ..setInt64(24, 0x100000201, Endian.little)
        ..setInt64(32, -0x100000001, Endian.little)
        ..setInt64(40, 0x200000002, Endian.little)
        ..setInt64(48, 0x300000003, Endian.little);
      final original = Uint8List.fromList(source.asTypedList(56));
      layout.write(allocation + 16, source);
      final expected = Uint8List(size);
      final fields = ByteData.sublistView(expected);
      fields
        ..setUint64(0, 0xfedcba98, Endian.little)
        ..setUint64(8, 0xabcd, Endian.little)
        ..setUint32(mode, 0x81ed, Endian.little)
        ..setUint32(links, 0x1234, Endian.little)
        ..setUint32(uid, 123, Endian.little)
        ..setUint32(gid, 456, Endian.little)
        ..setUint64(rdev, 0x87654321, Endian.little)
        ..setInt64(48, 0x100000201, Endian.little)
        ..setInt64(56, 4096, Endian.little)
        ..setInt64(64, 0x800002, Endian.little)
        ..setInt64(72, -0x100000001, Endian.little)
        ..setInt64(88, 0x200000002, Endian.little)
        ..setInt64(104, 0x300000003, Endian.little);
      expect((allocation + 16).asTypedList(size), expected);
      expect(allocation.asTypedList(16), everyElement(0xa5));
      expect((allocation + 16 + size).asTypedList(16), everyElement(0xa5));
      expect(source.asTypedList(56), original);
    });
  }

  for (final abi in Abi.values.where(
    (abi) => abi != Abi.windowsX64 && abi != Abi.windowsArm64,
  )) {
    test('Windows policy rejects $abi without loading host libraries', () {
      expect(() => WindowsAdiAbi.forAbi(abi), throwsUnsupportedError);
    });
  }

  test(
    'Windows loader rejects non-Windows ABI before native initialization',
    () => expect(WindowsNativeLibraryLoader.new, throwsUnsupportedError),
    skip: Abi.current() == Abi.windowsX64 || Abi.current() == Abi.windowsArm64,
  );

  test('timeval writes signed LP64 values at offsets zero and eight', () {
    expect(sizeOf<LinuxTimeval>(), 16);
    final allocation = calloc<Uint8>(32);
    addTearDown(() => calloc.free(allocation));
    allocation.asTypedList(32).fillRange(0, 32, 0xa5);
    final time = (allocation + 8).cast<LinuxTimeval>();
    time.ref
      ..tvSec = 0x100000001
      ..tvUsec = 999999;
    final bytes = ByteData.sublistView(allocation.asTypedList(32));
    expect(bytes.getInt64(8, Endian.little), 0x100000001);
    expect(bytes.getInt64(16, Endian.little), 999999);
    expect(allocation.asTypedList(8), everyElement(0xa5));
    expect((allocation + 24).asTypedList(8), everyElement(0xa5));
  });

  test('open translates flags and passes mode only for creation', () {
    expect(WindowsOpenFlags.fromLinux(0), 0x8000);
    expect(WindowsOpenFlags.fromLinux(1), 0x8001);
    expect(WindowsOpenFlags.fromLinux(2), 0x8002);
    expect(
      WindowsOpenFlags.fromLinux(0x40 | 0x80 | 0x200 | 0x400 | 0x80000 | 2),
      0x878a,
    );
    expect(WindowsOpenFlags.creationMode(0, 0xffffffff), 0);
    expect(WindowsOpenFlags.creationMode(0x40, 0x100), 0x100);
    for (final writePermission in [0x80, 0x10, 2]) {
      expect(WindowsOpenFlags.creationMode(0x40, writePermission), 0x180);
    }
    expect(linuxStatMode(0x8100), 0x816d);
    expect(linuxStatMode(0x4180), 0x41ed);
  });

  test('Android long conversions call LP64 CRT entrypoints', () {
    expect(WindowsCrt.androidSymbolName('strtol'), 'strtoll');
    expect(WindowsCrt.androidSymbolName('strtoul'), 'strtoull');
    final crt = WindowsCrt();
    final signed = crt
        .symbol('strtol')
        .cast<
          NativeFunction<
            Int64 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, Int32)
          >
        >()
        .asFunction<int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, int)>();
    final unsigned = crt
        .symbol('strtoul')
        .cast<
          NativeFunction<
            Uint64 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, Int32)
          >
        >()
        .asFunction<int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, int)>();
    final end = calloc<Pointer<Utf8>>();
    final negative = '-4294967297tail'.toNativeUtf8();
    final positive = '4294967297tail'.toNativeUtf8();
    addTearDown(() {
      calloc.free(end);
      malloc.free(negative);
      malloc.free(positive);
    });
    expect(signed(negative, end, 10), -4294967297);
    expect(end.value.toDartString(), 'tail');
    expect(unsigned(positive, end, 10), 4294967297);
    expect(end.value.toDartString(), 'tail');
  });
}
