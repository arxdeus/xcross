import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/auth_command.dart';
import 'package:xcross/src/errors.dart';

import 'auth_fixture.dart';

void main() {
  group('Apple ID host support', () {
    for (final abi in const [
      Abi.linuxX64,
      Abi.linuxArm64,
      Abi.macosX64,
      Abi.macosArm64,
      Abi.windowsX64,
    ]) {
      test('accepts $abi', () {
        expect(() => AuthCommand.requireAppleIdHost(abi), returnsNormally);
      });
    }

    for (final abi in const [
      Abi.windowsArm64,
      Abi.linuxArm,
      Abi.androidArm64,
    ]) {
      test('rejects $abi before prompting for credentials', () {
        expect(
          () => AuthCommand.requireAppleIdHost(abi),
          throwsA(isA<XcrossError>()),
        );
      });
    }
  });

  group('ADI library directory', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('xcross_auth_adi_');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    Future<AdiLibraryPaths> noFetch(AdiLibraryFetcher fetcher) {
      fail('Unexpected ADI download for ${fetcher.libraryDirectory.path}');
    }

    for (final style in [p.Style.posix, p.Style.windows]) {
      test(
        'ADI lookup uses only selected logical acquisitions on $style',
        () async {
          final fixture = AuthNamespaceFixture(style: style);
          addTearDown(fixture.dispose);
          final cache = fixture.path('adi-cache');
          final physical = fixture.fileSystem.directory(
            fixture.paths.context.join(cache, 'x86_64'),
          );
          _writeLibraries(physical, 62);
          fixture.fileSystem.acquisitions.clear();
          final command = authFixture(services: fixture.services);
          expect(
            await command.resolveAdiLibraryDirectory(
              cacheDirectory: cache,
              fetchLibraries: noFetch,
            ),
            cache,
          );
          final logicalResult = await command.resolveAdiLibraryDirectory(
            cacheDirectory: cache,
            fetchLibraries: noFetch,
          );
          expect(
            AdiLibraryResolver(
              hostServices: fixture.services,
            ).resolve(logicalResult, abi: Abi.linuxX64)?.path,
            physical.path,
          );
          expect(
            () => AdiLibraryResolver(
              hostServices: fixture.services,
            ).resolve(physical.path, abi: Abi.linuxX64),
            throwsStateError,
          );
          expect(fixture.fileSystem.acquisitions, isNotEmpty);
          expect(
            fixture.fileSystem.acquisitions.every(
              (path) => fixture.paths.context.isWithin(cache, path),
            ),
            isTrue,
          );
          fixture.fileSystem
              .file(
                fixture.paths.context.join(cache, 'x86_64', 'libCoreADI.so'),
              )
              .deleteSync();
          await expectLater(
            command.resolveAdiLibraryDirectory(
              cacheDirectory: cache,
              configuredDirectory: fixture.paths.context.join(cache, 'x86_64'),
              fetchLibraries: noFetch,
            ),
            throwsA(isA<XcrossError>()),
          );
        },
      );
    }

    for (final abi in const [Abi.linuxArm64, Abi.macosArm64]) {
      test('uses scoped ARM64 cache on $abi', () async {
        final libraries = Directory(p.join(root.path, 'arm64-v8a'));
        _writeLibraries(libraries, 183);
        _writeLibraries(root, 62);

        expect(
          await authFixture(abi: abi).resolveAdiLibraryDirectory(
            cacheDirectory: root.path,
            fetchLibraries: noFetch,
          ),
          root.absolute.path,
        );
      });
    }

    test('preserves matching legacy flat libraries', () async {
      _writeLibraries(root, 62);

      expect(
        await authFixture().resolveAdiLibraryDirectory(
          cacheDirectory: root.path,
          fetchLibraries: noFetch,
        ),
        root.absolute.path,
      );
    });

    test('fetches ARM64 without overwriting legacy x64 libraries', () async {
      _writeLibraries(root, 62);
      final original = File(
        p.join(root.path, 'libCoreADI.so'),
      ).readAsBytesSync();
      var fetches = 0;

      final result = await authFixture(abi: Abi.linuxArm64)
          .resolveAdiLibraryDirectory(
            cacheDirectory: root.path,
            fetchLibraries: (fetcher) async {
              fetches++;
              expect(
                fetcher.libraryDirectory.path,
                p.join(root.path, 'arm64-v8a'),
              );
              return _writeLibraries(fetcher.libraryDirectory, 183);
            },
          );

      expect(fetches, 1);
      expect(result, root.absolute.path);
      expect(
        File(p.join(root.path, 'libCoreADI.so')).readAsBytesSync(),
        original,
      );
    });

    test('accepts an explicit scoped directory without downloading', () async {
      final libraries = Directory(p.join(root.path, 'arm64-v8a'));
      _writeLibraries(libraries, 183);

      expect(
        await authFixture(abi: Abi.macosArm64).resolveAdiLibraryDirectory(
          cacheDirectory: Directory.systemTemp.path,
          configuredDirectory: libraries.path,
          fetchLibraries: noFetch,
        ),
        libraries.absolute.path,
      );
    });

    test('rejects mismatched explicit libraries without downloading', () async {
      _writeLibraries(root, 62);

      await expectLater(
        authFixture(abi: Abi.linuxArm64).resolveAdiLibraryDirectory(
          cacheDirectory: Directory.systemTemp.path,
          configuredDirectory: root.path,
          fetchLibraries: noFetch,
        ),
        throwsA(isA<XcrossError>()),
      );
      expect(Directory(p.join(root.path, 'arm64-v8a')).existsSync(), isFalse);
    });

    test('rejects incomplete explicit libraries without downloading', () async {
      _writeLibraries(root, 183);
      File(p.join(root.path, 'libstoreservicescore.so')).deleteSync();

      await expectLater(
        authFixture(abi: Abi.macosArm64).resolveAdiLibraryDirectory(
          cacheDirectory: Directory.systemTemp.path,
          configuredDirectory: root.path,
          fetchLibraries: noFetch,
        ),
        throwsA(isA<XcrossError>()),
      );
    });

    test('fetches into the host architecture directory', () async {
      final result = await authFixture(abi: Abi.windowsX64)
          .resolveAdiLibraryDirectory(
            cacheDirectory: root.path,
            fetchLibraries: (fetcher) async {
              expect(
                fetcher.libraryDirectory.path,
                p.join(root.path, 'x86_64'),
              );
              return _writeLibraries(fetcher.libraryDirectory, 62);
            },
          );

      expect(result, root.absolute.path);
    });

    test('rejects unsupported hosts without changing the cache', () async {
      await expectLater(
        authFixture(abi: Abi.windowsArm64).resolveAdiLibraryDirectory(
          cacheDirectory: root.path,
          fetchLibraries: noFetch,
        ),
        throwsA(isA<XcrossError>()),
      );
      expect(root.listSync(), isEmpty);
    });

    test('checks that a download actually produced libraries', () async {
      await expectLater(
        authFixture(abi: Abi.linuxArm64).resolveAdiLibraryDirectory(
          cacheDirectory: root.path,
          fetchLibraries: (fetcher) async => AdiLibraryPaths(
            coreAdiPath: fetcher.coreAdiFile.path,
            storeServicesPath: fetcher.storeServicesFile.path,
            apkSha256: 'fixture',
          ),
        ),
        throwsA(isA<XcrossError>()),
      );
    });
  });
}

AdiLibraryPaths _writeLibraries(Directory directory, int machine) {
  directory.createSync(recursive: true);
  final bytes = Uint8List(184);
  bytes.setRange(0, 7, [0x7f, 69, 76, 70, 2, 1, 1]);
  final data = ByteData.sublistView(bytes)
    ..setUint16(16, 3, Endian.little)
    ..setUint16(18, machine, Endian.little)
    ..setUint32(20, 1, Endian.little)
    ..setUint64(32, 64, Endian.little)
    ..setUint64(40, 120, Endian.little)
    ..setUint16(52, 64, Endian.little)
    ..setUint16(54, 56, Endian.little)
    ..setUint16(56, 1, Endian.little)
    ..setUint16(58, 64, Endian.little)
    ..setUint16(60, 1, Endian.little)
    ..setUint32(64, 1, Endian.little)
    ..setUint32(68, 4, Endian.little)
    ..setUint64(96, bytes.length, Endian.little)
    ..setUint64(104, bytes.length, Endian.little);
  final core = File(p.join(directory.path, 'libCoreADI.so'));
  final services = File(p.join(directory.path, 'libstoreservicescore.so'));
  core.writeAsBytesSync(data.buffer.asUint8List());
  services.writeAsBytesSync(data.buffer.asUint8List());
  return AdiLibraryPaths(
    coreAdiPath: core.path,
    storeServicesPath: services.path,
    apkSha256: 'fixture',
  );
}
