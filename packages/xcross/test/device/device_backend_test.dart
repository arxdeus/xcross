import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/device/device_backend.dart';
import 'package:xcross/src/errors.dart';

void main() {
  group('saved Apple ID session provider', () {
    final directory = p.join(Directory.systemTemp.absolute.path, 'adi-fixture');

    for (final abi in const [
      Abi.linuxX64,
      Abi.linuxArm64,
      Abi.macosX64,
      Abi.macosArm64,
      Abi.windowsX64,
    ]) {
      test('uses the saved ADI directory on $abi without IO', () {
        final provider = _NoIoAnisetteProvider();
        final directories = <String>[];
        final resolved = NativeBackend.anisetteForSession(
          _session(directory),
          hostAbi: abi,
          createProvider: (path) {
            directories.add(path);
            return provider;
          },
        );
        expect(resolved, same(provider));
        expect(directories, [directory]);
      });

      test('preserves the missing-directory error on $abi', () {
        expect(
          () => NativeBackend.anisetteForSession(
            _session(null),
            hostAbi: abi,
            createProvider: (_) => fail('Must reject before creating provider'),
          ),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              'Saved Apple ID session is missing adiLibraryDirectory. '
                  'Run xcross auth --apple-id <email> again.',
            ),
          ),
        );
      });
    }

    for (final abi in const [
      Abi.windowsArm64,
      Abi.linuxArm,
      Abi.androidArm64,
    ]) {
      for (final path in [directory, null]) {
        test('preflights unsupported $abi with directory $path', () {
          expect(
            () => NativeBackend.anisetteForSession(
              _session(path),
              hostAbi: abi,
              createProvider: (_) =>
                  fail('Must reject before creating provider'),
            ),
            throwsA(
              isA<XcrossError>().having(
                (error) => error.message,
                'message',
                'Saved native Apple ID sessions support Linux and macOS x64/ARM64 '
                    'and Windows x64 (got $abi).',
              ),
            ),
          );
        });
      }
    }

    test('uses the running ABI when no override is supplied', () {
      final provider = _NoIoAnisetteProvider();
      AnisetteProvider resolve() => NativeBackend.anisetteForSession(
        _session(directory),
        createProvider: (_) => provider,
      );
      if (AdiLibraryFetcher.supportsAbi(Abi.current())) {
        expect(resolve(), same(provider));
      } else {
        expect(resolve, throwsA(isA<XcrossError>()));
      }
    });
  });

  test('always resolves the native backend', () async {
    expect(await DeviceBackend.resolve(), isA<NativeBackend>());
  });

  test('rejects non-app inputs before provisioning mutates Apple state', () {
    final uri = Isolate.resolvePackageUriSync(
      Uri.parse('package:xcross/src/device/device_backend.dart'),
    )!;
    final source = File.fromUri(uri).readAsStringSync();
    final guard = source.indexOf(
      'in-process signer currently supports xcross-generated .app',
    );
    final provision = source.indexOf(
      'await AscProvisioning.provisionDevelopmentIdentity(',
    );

    expect(guard, greaterThanOrEqualTo(0));
    expect(provision, greaterThan(guard));
    expect(source, isNot(contains('ZsignCli')));
  });
}

GrandSlamSession _session(String? directory) => GrandSlamSession(
  username: 'fixture@example.invalid',
  token: DeveloperServicesLoginToken(
    adsid: 'fixture',
    token: 'not-a-real-token',
    expiry: DateTime.utc(2099),
  ),
  teamId: 'FIXTURE',
  adiLibraryDirectory: directory,
);

final class _NoIoAnisetteProvider implements AnisetteProvider {
  @override
  Future<Map<String, String>> fetchAnisetteHeaders() =>
      throw StateError('Provider construction must not fetch headers');

  @override
  Future<GrandSlamEndpoints> resolveGrandSlamEndpoints() =>
      throw StateError('Provider construction must not resolve endpoints');

  @override
  void close() {}
}
