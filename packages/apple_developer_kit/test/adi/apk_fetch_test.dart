import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/apk_fetch.dart';
import 'package:archive/archive.dart';
import 'package:test/test.dart';

import 'support/elf_fixture.dart';

void main() {
  late Directory cache;
  setUp(() => cache = Directory.systemTemp.createTempSync('adi-fetch-test-'));
  tearDown(() => cache.deleteSync(recursive: true));

  void writeApk({bool arm64 = true, bool x64 = true, bool wrongArm = false}) {
    final archive = Archive();
    for (final (abi, machine) in [
      if (arm64) ('arm64-v8a', wrongArm ? 62 : 183),
      if (x64) ('x86_64', 62),
    ]) {
      for (final name in ['libCoreADI.so', 'libstoreservicescore.so']) {
        final bytes = elfFixture(machine);
        archive.addFile(ArchiveFile('lib/$abi/$name', bytes.length, bytes));
      }
    }
    File(
      '${cache.path}/applemusic.apk',
    ).writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test('host selection allows ARM64 POSIX and keeps Windows x64-only', () {
    for (final abi in [
      Abi.linuxX64,
      Abi.linuxArm64,
      Abi.macosX64,
      Abi.macosArm64,
      Abi.windowsX64,
    ]) {
      expect(AdiLibraryFetcher.supportsAbi(abi), isTrue);
    }
    for (final abi in [
      Abi.windowsArm64,
      Abi.linuxArm,
      Abi.androidArm64,
      Abi.iosArm64,
    ]) {
      expect(AdiLibraryFetcher.supportsAbi(abi), isFalse);
      expect(
        () => AdiLibraryFetcher(cacheDir: cache, abi: abi),
        throwsUnsupportedError,
      );
    }
  });

  test('extracts both host slices into independent caches', () async {
    writeApk();
    final arm = AdiLibraryFetcher(cacheDir: cache, abi: Abi.linuxArm64);
    final x64 = AdiLibraryFetcher(cacheDir: cache, abi: Abi.linuxX64);
    final a = await arm.ensureLibraries();
    final x = await x64.ensureLibraries();
    expect(a.coreAdiPath, contains('arm64-v8a'));
    expect(x.coreAdiPath, contains('x86_64'));
    expect(a.apkSha256, x.apkSha256);
    expect(
      AdiLibraryFetcher.resolveLibraryDirectory(
        cache,
        abi: Abi.macosArm64,
      )?.path,
      arm.libraryDirectory.path,
    );
    expect(
      AdiLibraryFetcher.resolveLibraryDirectory(
        cache,
        abi: Abi.windowsX64,
      )?.path,
      x64.libraryDirectory.path,
    );
    final cached = await arm.ensureLibraries();
    expect(cached.coreAdiPath, a.coreAdiPath);
  });

  test('never falls back to wrong APK architecture', () async {
    writeApk(arm64: false);
    final fetcher = AdiLibraryFetcher(cacheDir: cache, abi: Abi.linuxArm64);
    await expectLater(fetcher.ensureLibraries(), throwsStateError);
    expect(fetcher.coreAdiFile.existsSync(), isFalse);
  });

  test('validates actual machine before writing a slice', () async {
    writeApk(wrongArm: true);
    final fetcher = AdiLibraryFetcher(cacheDir: cache, abi: Abi.linuxArm64);
    await expectLater(fetcher.ensureLibraries(), throwsFormatException);
    expect(fetcher.coreAdiFile.existsSync(), isFalse);
  });

  test(
    'rejects poisoned scoped cache and legacy architecture mismatch',
    () async {
      writeApk();
      final fetcher = AdiLibraryFetcher(cacheDir: cache, abi: Abi.linuxArm64);
      await fetcher.ensureLibraries();
      fetcher.coreAdiFile.writeAsBytesSync(elfFixture(62));
      await expectLater(fetcher.ensureLibraries(), throwsFormatException);
      for (final name in ['libCoreADI.so', 'libstoreservicescore.so']) {
        File('${cache.path}/$name').writeAsBytesSync(elfFixture(183));
      }
      expect(
        () => AdiLibraryFetcher.resolveLibraryDirectory(
          cache,
          abi: Abi.windowsX64,
        ),
        throwsFormatException,
      );
    },
  );

  test('accepts matching legacy flat library directories', () {
    expect(
      AdiLibraryFetcher.resolveLibraryDirectory(cache, abi: Abi.linuxArm64),
      isNull,
    );
    for (final name in ['libCoreADI.so', 'libstoreservicescore.so']) {
      File('${cache.path}/$name').writeAsBytesSync(elfFixture(183));
    }
    expect(
      AdiLibraryFetcher.resolveLibraryDirectory(
        cache,
        abi: Abi.linuxArm64,
      )?.path,
      cache.path,
    );
  });

  for (final mutation in ['magic', 'class', 'endian', 'truncated']) {
    test('rejects $mutation cached ELF safely', () {
      final bytes = elfFixture(183);
      switch (mutation) {
        case 'magic':
          bytes[0] = 0;
        case 'class':
          bytes[4] = 1;
        case 'endian':
          bytes[5] = 2;
        case 'truncated':
          ByteData.sublistView(
            bytes,
          ).setUint64(32, bytes.length, Endian.little);
      }
      for (final name in ['libCoreADI.so', 'libstoreservicescore.so']) {
        File('${cache.path}/$name').writeAsBytesSync(bytes);
      }
      expect(
        () => AdiLibraryFetcher.resolveLibraryDirectory(
          cache,
          abi: Abi.linuxArm64,
        ),
        throwsFormatException,
      );
    });
  }
}
