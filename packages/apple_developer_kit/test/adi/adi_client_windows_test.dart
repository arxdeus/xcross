@TestOn('windows')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/shared/adi/apk_fetch.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/sysv_abi_bridge.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/native_symbol_stubs_windows.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/windows_adi_abi.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/loader_windows.dart';
import 'package:apple_developer_kit/src/shared/adi/adi_client.dart';
import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../support/host_services.dart';
import 'support/elf_fixture.dart';

void main() {
  test('native Windows stubs preserve LP64 results and stat bounds', () {
    final directory = Directory.systemTemp.createTempSync('adi-windows-abi-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final abi = WindowsAdiAbi.forAbi(Abi.current());
    final stubs = WindowsNativeSymbolStubs(
      abi: abi,
      loadLibraryForDlopen: (_) => throw StateError('Unexpected dlopen'),
    );
    final open = SysvAbiBridge.sysvImport(
      stubs
          .resolve('open')
          .cast<NativeFunction<Int32 Function(Pointer<Utf8>, Int32, Int32)>>(),
      3,
    ).asFunction<int Function(Pointer<Utf8>, int, int)>();
    final close = SysvAbiBridge.sysvImport(
      stubs.resolve('close').cast<NativeFunction<Int32 Function(Int32)>>(),
      1,
    ).asFunction<int Function(int)>();
    final write = SysvAbiBridge.sysvImport(
      stubs
          .resolve('write')
          .cast<
            NativeFunction<IntPtr Function(Int32, Pointer<Void>, UintPtr)>
          >(),
      3,
    ).asFunction<int Function(int, Pointer<Void>, int)>();
    final read = SysvAbiBridge.sysvImport(
      stubs
          .resolve('read')
          .cast<
            NativeFunction<IntPtr Function(Int32, Pointer<Void>, UintPtr)>
          >(),
      3,
    ).asFunction<int Function(int, Pointer<Void>, int)>();
    final fstat = SysvAbiBridge.sysvImport(
      stubs
          .resolve('fstat')
          .cast<NativeFunction<Int32 Function(Int32, Pointer<Uint8>)>>(),
      2,
    ).asFunction<int Function(int, Pointer<Uint8>)>();
    using((arena) {
      final path = '${directory.path}/created.bin'.toNativeUtf8(
        allocator: arena,
      );
      final fd = open(path, 0x40 | 2, 0x180);
      expect(fd, greaterThanOrEqualTo(0));
      try {
        final payload = arena<Uint8>()..value = 0x5a;
        expect(write(fd, payload.cast(), 1), 1);
        expect(read(fd, payload.cast(), 0x100000000), -1);
        expect(write(fd, payload.cast(), 0x100000000), -1);
        final output = arena<Uint8>(abi.statLayout.size + 32);
        output
            .asTypedList(abi.statLayout.size + 32)
            .fillRange(0, abi.statLayout.size + 32, 0xa5);
        expect(fstat(fd, output + 16), 0);
        final fields = ByteData.sublistView(
          (output + 16).asTypedList(abi.statLayout.size),
        );
        expect(fields.getInt64(48, Endian.little), 1);
        final modeOffset = Abi.current() == Abi.windowsArm64 ? 16 : 24;
        final nlinkOffset = Abi.current() == Abi.windowsArm64 ? 20 : 16;
        expect(fields.getUint32(modeOffset, Endian.little) & 0xf080, 0x8080);
        expect(fields.getUint32(nlinkOffset, Endian.little), 1);
        expect(fields.getInt64(56, Endian.little), 4096);
        expect(fields.getInt64(64, Endian.little), 1);
        for (final offset in [72, 88, 104]) {
          expect(fields.getInt64(offset, Endian.little), greaterThan(0));
          expect(fields.getInt64(offset + 8, Endian.little), 0);
        }
        expect(output.asTypedList(16), everyElement(0xa5));
        expect(
          (output + 16 + abi.statLayout.size).asTypedList(16),
          everyElement(0xa5),
        );
      } finally {
        expect(close(fd), 0);
      }
    });
    expect(File('${directory.path}/created.bin').readAsBytesSync(), [0x5a]);
  }, skip: Platform.environment['ADI_NATIVE_SMOKE'] != '1');

  test(
    'rejects another ELF machine before native initialization',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'adi-wrong-machine-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/wrong.so';
      final machine = Abi.current() == Abi.windowsArm64 ? 62 : 183;
      File(path).writeAsBytesSync(elfFixture(machine));
      expect(
        () => WindowsNativeLibraryLoader().load(path),
        throwsFormatException,
      );
    },
    skip: Abi.current() != Abi.windowsArm64 && Abi.current() != Abi.windowsX64,
  );

  // Downloads the real Apple Music APK on first run (not redistributed;
  // see NOTICE.md). Proves Windows VirtualAlloc ELF load + SysV bridge +
  // ADI symbol resolution. Does not call Apple provisioning endpoints.
  test(
    'native ADI library can be fetched, ELF-loaded on Windows, and symbols resolved',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'adi-windows-smoke-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final fetcher = AdiLibraryFetcher(
        hostServices: testHostServices,
        cacheDir: directory.path,
        abi: testHostServices.abi,
        createClient: http.Client.new,
      );
      final paths = await fetcher.ensureLibraries();

      expect(File(paths.coreAdiPath).existsSync(), isTrue);
      expect(File(paths.storeServicesPath).existsSync(), isTrue);
      expect(paths.apkSha256, isNotEmpty);

      final client = AdiClient.fromDirectory(
        fetcher.libraryDirectory.path,
        loader: testNativeLoader(),
      );
      expect(client, isNotNull);
      // First real ADI calls (hits SysV import trampolines). A bad bridge
      // used to kill the process here with no Dart exception.
      final provisioningDirectory = Directory('${directory.path}/provisioning')
        ..createSync();
      client.provisioningPath =
          '${provisioningDirectory.path.replaceAll(r'\', '/')}/';
      client.identifier = '0123456789abcdef';
      // -2 is the conventional "DSID unknown / not provisioned" probe.
      final provisioned = await client.isMachineProvisioned(-2);
      expect(provisioned, isA<bool>());
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: Platform.environment['ADI_NATIVE_SMOKE'] != '1'
        ? 'Set ADI_NATIVE_SMOKE=1 for isolated real Apple APK validation.'
        : Abi.current() == Abi.windowsX64 || Abi.current() == Abi.windowsArm64
        ? null
        : 'ADI requires Windows x64 or ARM64 (host is ${Abi.current()}).',
  );
}
