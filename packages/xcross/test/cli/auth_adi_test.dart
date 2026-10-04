import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/shared/adi/apk_fetch.dart';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/basic/auth_command.dart';
import 'package:xcross/src/shared/errors/errors.dart';

import 'auth_fixture.dart';

void main() {
  group('Apple ID host support', () {
    for (final abi in const [
      Abi.linuxX64,
      Abi.linuxArm64,
      Abi.macosX64,
      Abi.macosArm64,
      Abi.windowsX64,
      Abi.windowsArm64,
    ]) {
      test('accepts $abi', () {
        expect(() => AuthCommand.requireAppleIdHost(abi), returnsNormally);
      });
    }

    for (final abi in const [Abi.windowsIA32, Abi.linuxArm, Abi.androidArm64]) {
      test('rejects $abi before prompting for credentials', () {
        expect(
          () => AuthCommand.requireAppleIdHost(abi),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              'Built-in Apple ID/password login supports Linux and macOS x64/ARM64 '
                  'and Windows x64/ARM64 (got $abi). '
                  'On this platform use App Store Connect API key flags.',
            ),
          ),
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
            await command.resolveAdiLibraryDirectory(cacheDirectory: cache),
            cache,
          );
          final logicalResult = await command.resolveAdiLibraryDirectory(
            cacheDirectory: cache,
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
            ),
            throwsA(isA<XcrossError>()),
          );
        },
      );
    }

    for (final style in [p.Style.posix, p.Style.windows]) {
      test(
        'ADI fetch uses constructor HTTP and selected writes on $style',
        () async {
          final fixture = AuthNamespaceFixture(style: style);
          addTearDown(fixture.dispose);
          final client = ClosingAuthApkClient(_apkBytes(62, 'x86_64'));
          final cache = fixture.path('download-cache');
          final command = authFixture(
            services: fixture.services,
            createAdiHttpClient: () => client,
          );
          expect(
            await command.resolveAdiLibraryDirectory(cacheDirectory: cache),
            cache,
          );
          expect(client.closed, isTrue);
          expect(
            AdiLibraryResolver(
              hostServices: fixture.services,
            ).resolve(cache, abi: Abi.linuxX64),
            isNotNull,
          );
          expect(
            fixture.fileSystem.acquisitions.every(
              (value) =>
                  value == cache ||
                  fixture.paths.context.isWithin(cache, value),
            ),
            isTrue,
          );
        },
      );
    }

    for (final abi in const [
      Abi.linuxArm64,
      Abi.macosArm64,
      Abi.windowsArm64,
    ]) {
      test('uses scoped ARM64 cache on $abi', () async {
        final libraries = Directory(p.join(root.path, 'arm64-v8a'));
        _writeLibraries(libraries, 183);
        _writeLibraries(root, 62);

        expect(
          await authFixture(
            abi: abi,
          ).resolveAdiLibraryDirectory(cacheDirectory: root.path),
          root.absolute.path,
        );
      });
    }

    test('preserves matching legacy flat libraries', () async {
      _writeLibraries(root, 62);

      expect(
        await authFixture().resolveAdiLibraryDirectory(
          cacheDirectory: root.path,
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
      final result = await authFixture(
        abi: Abi.linuxArm64,
        createAdiHttpClient: () => MockClient((request) async {
          fetches++;
          expect(request.url.toString(), appleMusicApkUrl);
          return http.Response.bytes(_apkBytes(183, 'arm64-v8a'), 200);
        }),
      ).resolveAdiLibraryDirectory(cacheDirectory: root.path);
      expect(fetches, 1);
      expect(result, root.absolute.path);
      expect(
        File(p.join(root.path, 'arm64-v8a', 'libCoreADI.so')).existsSync(),
        isTrue,
      );
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
        ),
        throwsA(isA<XcrossError>()),
      );
    });

    for (final (abi, machine, architecture) in const [
      (Abi.windowsX64, 62, 'x86_64'),
      (Abi.windowsArm64, 183, 'arm64-v8a'),
    ]) {
      test('fetches into the host architecture directory on $abi', () async {
        final client = ClosingAuthApkClient(_apkBytes(machine, architecture));
        final result = await authFixture(
          abi: abi,
          createAdiHttpClient: () => client,
        ).resolveAdiLibraryDirectory(cacheDirectory: root.path);
        expect(result, root.absolute.path);
        expect(client.closed, isTrue);
        for (final name in ['libCoreADI.so', 'libstoreservicescore.so']) {
          expect(
            File(p.join(root.path, architecture, name)).readAsBytesSync(),
            _libraryBytes(machine),
          );
        }
      });
    }

    test('rejects unsupported hosts without changing the cache', () async {
      await expectLater(
        authFixture(
          abi: Abi.windowsIA32,
        ).resolveAdiLibraryDirectory(cacheDirectory: root.path),
        throwsA(isA<XcrossError>()),
      );
      expect(root.listSync(), isEmpty);
    });

    test(
      'rejects incomplete downloaded APK without producing a library pair',
      () async {
        await expectLater(
          authFixture(
            abi: Abi.linuxArm64,
            createAdiHttpClient: () => MockClient(
              (_) async => http.Response.bytes(
                _apkBytes(183, 'arm64-v8a', complete: false),
                200,
              ),
            ),
          ).resolveAdiLibraryDirectory(cacheDirectory: root.path),
          throwsStateError,
        );
        expect(Directory(p.join(root.path, 'arm64-v8a')).existsSync(), isFalse);
      },
    );
  });
}

AdiLibraryPaths _writeLibraries(Directory directory, int machine) {
  directory.createSync(recursive: true);
  final data = ByteData.sublistView(_libraryBytes(machine));
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

Uint8List _libraryBytes(int machine) {
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
  return data.buffer.asUint8List();
}

List<int> _apkBytes(int machine, String architecture, {bool complete = true}) {
  final bytes = _libraryBytes(machine);
  final archive = Archive();
  for (final name in [
    'libCoreADI.so',
    if (complete) 'libstoreservicescore.so',
  ]) {
    archive.addFile(
      ArchiveFile('lib/$architecture/$name', bytes.length, bytes),
    );
  }
  return ZipEncoder().encode(archive);
}

@internal
final class ClosingAuthApkClient extends MockClient {
  ClosingAuthApkClient(List<int> bytes)
    : super((_) async => http.Response.bytes(bytes, 200));
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}
