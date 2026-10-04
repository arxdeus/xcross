import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/shared/adi/apk_fetch.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../support/host_services.dart';
import '../support/mapped_apple_fixture.dart';
import 'support/elf_fixture.dart';

class RecordingApkClient extends MockClient {
  RecordingApkClient(super.handler, {this.closeError});

  final Error? closeError;
  int closeCount = 0;

  @override
  void close() {
    closeCount++;
    super.close();
    final error = closeError;
    if (error != null) throw error;
  }
}

void main() {
  test(
    'mapped filesystem downloads, hashes, extracts and resolves without native bypass',
    () async {
      final fixture = MappedAppleFixture();
      addTearDown(fixture.dispose);
      final archive = Archive();
      for (final name in ['libCoreADI.so', 'libstoreservicescore.so']) {
        final bytes = elfFixture(183);
        archive.addFile(
          ArchiveFile('lib/arm64-v8a/$name', bytes.length, bytes),
        );
      }
      final bytes = ZipEncoder().encode(archive);
      final client = RecordingApkClient(
        (_) async => http.Response.bytes(bytes, 200),
      );
      final logicalCache = fixture.path('cache');
      final fetcher = AdiLibraryFetcher(
        cacheDir: logicalCache,
        hostServices: fixture.services,
        abi: Abi.linuxArm64,
        createClient: () => client,
      );
      final result = await fetcher.ensureLibraries();
      expect(client.closeCount, 1);
      expect(result.apkSha256, sha256.convert(bytes).toString());
      expect(fetcher.coreAdiFile.readAsBytesSync(), elfFixture(183));
      expect(fetcher.storeServicesFile.readAsBytesSync(), elfFixture(183));
      expect(File('$logicalCache/applemusic.apk').existsSync(), isFalse);
      final cached = AdiLibraryFetcher(
        cacheDir: logicalCache,
        hostServices: fixture.services,
        abi: Abi.linuxArm64,
        createClient: () => throw StateError('Unexpected download'),
      );
      expect((await cached.ensureLibraries()).apkSha256, result.apkSha256);
      final resolver = AdiLibraryResolver(hostServices: fixture.services);
      expect(
        resolver.resolve(logicalCache, abi: Abi.macosArm64)?.path,
        fetcher.libraryDirectory.path,
      );
      expect(
        resolver.resolve(fixture.path('missing'), abi: Abi.linuxArm64),
        isNull,
      );
      fixture.fileSystem.directory(fixture.path('flat')).createSync();
      for (final name in ['libCoreADI.so', 'libstoreservicescore.so']) {
        fixture.fileSystem
            .file(fixture.path('flat/$name'))
            .writeAsBytesSync(elfFixture(183));
      }
      expect(
        resolver.resolve(fixture.path('flat'), abi: Abi.linuxArm64)?.path,
        '${fixture.backingRoot}/flat',
      );
      fixture.fileSystem
          .file(fixture.path('flat/libCoreADI.so'))
          .writeAsBytesSync(elfFixture(62));
      expect(
        () => resolver.resolve(fixture.path('flat'), abi: Abi.linuxArm64),
        throwsFormatException,
      );
    },
  );

  late Directory cache;
  setUp(() => cache = Directory.systemTemp.createTempSync('adi-fetch-test-'));
  tearDown(() => cache.deleteSync(recursive: true));

  http.Client unexpectedClient() =>
      throw StateError('Cached artifacts must not create a client');

  List<int> apkBytes({
    bool arm64 = true,
    bool x64 = true,
    bool wrongArm = false,
  }) {
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
    return ZipEncoder().encode(archive);
  }

  void writeApk({bool arm64 = true, bool x64 = true, bool wrongArm = false}) {
    File(
      '${cache.path}/applemusic.apk',
    ).writeAsBytesSync(apkBytes(arm64: arm64, x64: x64, wrongArm: wrongArm));
  }

  test(
    'downloads through one owned client then reuses cached libraries',
    () async {
      final bytes = apkBytes();
      var creates = 0;
      var requests = 0;
      final client = RecordingApkClient((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.url, Uri.parse(appleMusicApkUrl));
        return http.Response.bytes(bytes, 200);
      });
      final fetcher = AdiLibraryFetcher(
        hostServices: testHostServices,
        cacheDir: cache.path,
        abi: Abi.linuxArm64,
        createClient: () {
          creates++;
          return client;
        },
      );
      expect(creates, 0);
      final paths = await fetcher.ensureLibraries();
      expect(paths.apkSha256, hasLength(64));
      expect(fetcher.coreAdiFile.readAsBytesSync(), elfFixture(183));
      expect(File('${cache.path}/applemusic.apk').readAsBytesSync(), bytes);
      await fetcher.ensureLibraries();
      expect(creates, 1);
      expect(requests, 1);
      expect(client.closeCount, 1);
    },
  );

  for (final closeThrows in [false, true]) {
    test('preserves request error with closeThrows=$closeThrows', () async {
      final failure = StateError('request failed');
      final stack = StackTrace.current;
      final client = RecordingApkClient(
        (_) => Future<http.Response>.error(failure, stack),
        closeError: closeThrows ? StateError('close failed') : null,
      );
      final fetcher = AdiLibraryFetcher(
        hostServices: testHostServices,
        cacheDir: cache.path,
        abi: Abi.linuxArm64,
        createClient: () => client,
      );
      try {
        await fetcher.ensureLibraries();
        fail('Expected request error');
      } catch (error, actualStack) {
        expect(error, same(failure));
        expect(actualStack.toString(), stack.toString());
      }
      expect(client.closeCount, 1);
      expect(File('${cache.path}/applemusic.apk').existsSync(), isFalse);
    });

    test('preserves HTTP error with closeThrows=$closeThrows', () async {
      final client = RecordingApkClient(
        (_) async => http.Response('unavailable', 503),
        closeError: closeThrows ? StateError('close failed') : null,
      );
      final fetcher = AdiLibraryFetcher(
        hostServices: testHostServices,
        cacheDir: cache.path,
        abi: Abi.linuxArm64,
        createClient: () => client,
      );
      await expectLater(
        fetcher.ensureLibraries(),
        throwsA(
          isA<HttpException>().having(
            (error) => error.message,
            'message',
            contains('HTTP 503'),
          ),
        ),
      );
      expect(client.closeCount, 1);
      expect(File('${cache.path}/applemusic.apk').existsSync(), isFalse);
    });

    test('preserves write error with closeThrows=$closeThrows', () async {
      final client = RecordingApkClient((_) async {
        Directory('${cache.path}/applemusic.apk').createSync();
        return http.Response.bytes(apkBytes(), 200);
      }, closeError: closeThrows ? StateError('close failed') : null);
      final fetcher = AdiLibraryFetcher(
        hostServices: testHostServices,
        cacheDir: cache.path,
        abi: Abi.linuxArm64,
        createClient: () => client,
      );
      await expectLater(
        fetcher.ensureLibraries(),
        throwsA(isA<FileSystemException>()),
      );
      expect(client.closeCount, 1);
    });
  }

  test('reports close failure when download succeeds', () async {
    final failure = StateError('close failed');
    final client = RecordingApkClient(
      (_) async => http.Response.bytes(apkBytes(), 200),
      closeError: failure,
    );
    final fetcher = AdiLibraryFetcher(
      hostServices: testHostServices,
      cacheDir: cache.path,
      abi: Abi.linuxArm64,
      createClient: () => client,
    );
    await expectLater(fetcher.ensureLibraries(), throwsA(same(failure)));
    expect(client.closeCount, 1);
    expect(File('${cache.path}/applemusic.apk').existsSync(), isTrue);
    final retry = AdiLibraryFetcher(
      hostServices: testHostServices,
      cacheDir: cache.path,
      abi: Abi.linuxArm64,
      createClient: unexpectedClient,
    );
    await retry.ensureLibraries();
  });

  test('propagates factory failure without creating APK', () async {
    final failure = StateError('factory failed');
    final fetcher = AdiLibraryFetcher(
      hostServices: testHostServices,
      cacheDir: cache.path,
      abi: Abi.linuxArm64,
      createClient: () => throw failure,
    );
    await expectLater(fetcher.ensureLibraries(), throwsA(same(failure)));
    expect(File('${cache.path}/applemusic.apk').existsSync(), isFalse);
  });

  test('closes client before rejecting invalid downloaded ELF', () async {
    final client = RecordingApkClient(
      (_) async => http.Response.bytes(apkBytes(wrongArm: true), 200),
    );
    final fetcher = AdiLibraryFetcher(
      hostServices: testHostServices,
      cacheDir: cache.path,
      abi: Abi.linuxArm64,
      createClient: () => client,
    );
    await expectLater(fetcher.ensureLibraries(), throwsFormatException);
    expect(client.closeCount, 1);
    expect(fetcher.coreAdiFile.existsSync(), isFalse);
  });

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
        () => AdiLibraryFetcher(
          hostServices: testHostServices,
          cacheDir: cache.path,
          abi: abi,
          createClient: unexpectedClient,
        ),
        throwsUnsupportedError,
      );
    }
  });

  test('extracts both host slices into independent caches', () async {
    writeApk();
    final arm = AdiLibraryFetcher(
      hostServices: testHostServices,
      cacheDir: cache.path,
      abi: Abi.linuxArm64,
      createClient: unexpectedClient,
    );
    final x64 = AdiLibraryFetcher(
      hostServices: testHostServices,
      cacheDir: cache.path,
      abi: Abi.linuxX64,
      createClient: unexpectedClient,
    );
    final a = await arm.ensureLibraries();
    final x = await x64.ensureLibraries();
    expect(a.coreAdiPath, contains('arm64-v8a'));
    expect(x.coreAdiPath, contains('x86_64'));
    expect(a.apkSha256, x.apkSha256);
    expect(
      AdiLibraryResolver(
        hostServices: testHostServices,
      ).resolve(cache.path, abi: Abi.macosArm64)?.path,
      arm.libraryDirectory.path,
    );
    expect(
      AdiLibraryResolver(
        hostServices: testHostServices,
      ).resolve(cache.path, abi: Abi.windowsX64)?.path,
      x64.libraryDirectory.path,
    );
    final cached = await arm.ensureLibraries();
    expect(cached.coreAdiPath, a.coreAdiPath);
    File('${cache.path}/applemusic.apk').deleteSync();
    expect((await arm.ensureLibraries()).apkSha256, a.apkSha256);
  });

  test('never falls back to wrong APK architecture', () async {
    writeApk(arm64: false);
    final fetcher = AdiLibraryFetcher(
      hostServices: testHostServices,
      cacheDir: cache.path,
      abi: Abi.linuxArm64,
      createClient: unexpectedClient,
    );
    await expectLater(fetcher.ensureLibraries(), throwsStateError);
    expect(fetcher.coreAdiFile.existsSync(), isFalse);
  });

  test('validates actual machine before writing a slice', () async {
    writeApk(wrongArm: true);
    final fetcher = AdiLibraryFetcher(
      hostServices: testHostServices,
      cacheDir: cache.path,
      abi: Abi.linuxArm64,
      createClient: unexpectedClient,
    );
    await expectLater(fetcher.ensureLibraries(), throwsFormatException);
    expect(fetcher.coreAdiFile.existsSync(), isFalse);
  });

  test(
    'repairs scoped cache but rejects explicit mismatches without mutation',
    () async {
      writeApk();
      final fetcher = AdiLibraryFetcher(
        hostServices: testHostServices,
        cacheDir: cache.path,
        abi: Abi.linuxArm64,
        createClient: unexpectedClient,
      );
      await fetcher.ensureLibraries();
      fetcher.coreAdiFile.writeAsBytesSync(elfFixture(62));
      expect(
        () => AdiLibraryResolver(
          hostServices: testHostServices,
        ).resolve(cache.path, abi: Abi.linuxArm64),
        throwsFormatException,
      );
      expect(fetcher.coreAdiFile.readAsBytesSync(), elfFixture(62));
      await fetcher.ensureLibraries();
      expect(fetcher.coreAdiFile.readAsBytesSync(), elfFixture(183));
      for (final name in ['libCoreADI.so', 'libstoreservicescore.so']) {
        File('${cache.path}/$name').writeAsBytesSync(elfFixture(183));
      }
      expect(
        () => AdiLibraryResolver(
          hostServices: testHostServices,
        ).resolve(cache.path, abi: Abi.windowsX64),
        throwsFormatException,
      );
    },
  );

  test('accepts matching legacy flat library directories', () {
    expect(
      AdiLibraryResolver(
        hostServices: testHostServices,
      ).resolve(cache.path, abi: Abi.linuxArm64),
      isNull,
    );
    for (final name in ['libCoreADI.so', 'libstoreservicescore.so']) {
      File('${cache.path}/$name').writeAsBytesSync(elfFixture(183));
    }
    expect(
      AdiLibraryResolver(
        hostServices: testHostServices,
      ).resolve(cache.path, abi: Abi.linuxArm64)?.path,
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
        () => AdiLibraryResolver(
          hostServices: testHostServices,
        ).resolve(cache.path, abi: Abi.linuxArm64),
        throwsFormatException,
      );
    });
  }
}
