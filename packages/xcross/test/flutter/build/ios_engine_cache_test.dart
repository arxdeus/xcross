import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
  late Directory temporaryDirectory;
  late String flutterRoot;
  late String cacheRoot;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'xcross_ios_engine_cache-',
    );
    flutterRoot = p.join(temporaryDirectory.path, 'flutter');
    cacheRoot = p.join(temporaryDirectory.path, 'cache');
    final internal = Directory(p.join(flutterRoot, 'bin', 'internal'));
    await internal.create(recursive: true);
    await File(
      p.join(internal.path, 'engine.version'),
    ).writeAsString('engine-hash\n');
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  for (final (abi, artifactPlatform, cacheDirectory) in [
    (Abi.linuxArm64, 'linux-arm64', 'linux-arm64'),
    (Abi.linuxX64, 'linux-x64', 'linux-x64'),
    (Abi.macosArm64, 'darwin-arm64', 'darwin-x64'),
    (Abi.macosX64, 'darwin-x64', 'darwin-x64'),
    (Abi.windowsX64, 'windows-x64', 'windows-x64'),
  ]) {
    test('$abi separates host downloads, SDK cache and iOS target', () {
      final cache = IosEngineCache(
        flutterRoot: flutterRoot,
        cacheRoot: cacheRoot,
        hostAbi: abi,
      );
      expect(cache.hostArtifactPlatform, artifactPlatform);
      expect(cache.hostEngineCacheDirectory, cacheDirectory);
      expect(
        cache.hostArtifactsUrl,
        'https://storage.googleapis.com/flutter_infra_release/flutter/'
        'engine-hash/$artifactPlatform/artifacts.zip',
      );
      expect(p.basename(p.dirname(cache.vmSnapshotData)), artifactPlatform);
      expect(p.basename(p.dirname(cache.flutterXcframework)), 'ios');
      expect(p.basename(cache.patchedSdkRoot), 'flutter_patched_sdk');

      final sdkHost = p.join(
        flutterRoot,
        'bin',
        'cache',
        'artifacts',
        'engine',
        cacheDirectory,
      );
      Directory(sdkHost).createSync(recursive: true);
      File(p.join(sdkHost, 'vm_isolate_snapshot.bin')).writeAsStringSync('vm');
      File(
        p.join(sdkHost, 'isolate_snapshot.bin'),
      ).writeAsStringSync('isolate');
      expect(cache.vmSnapshotData, p.join(sdkHost, 'vm_isolate_snapshot.bin'));
      expect(
        cache.isolateSnapshotData,
        p.join(sdkHost, 'isolate_snapshot.bin'),
      );
    });
  }

  for (final abi in [Abi.windowsArm64, Abi.linuxArm, Abi.androidArm64]) {
    test('rejects unsupported $abi instead of selecting x64 artifacts', () {
      expect(
        () => IosEngineCache(flutterRoot: flutterRoot, hostAbi: abi),
        throwsA(isA<FlutterBuildError>()),
      );
    });
  }

  test('does not reuse x64 Linux artifacts for an ARM64 host', () {
    final sdkHost = Directory(
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine', 'linux-x64'),
    )..createSync(recursive: true);
    for (final name in ['vm_isolate_snapshot.bin', 'isolate_snapshot.bin']) {
      File(p.join(sdkHost.path, name)).writeAsStringSync('x64');
    }
    final cache = IosEngineCache(
      flutterRoot: flutterRoot,
      cacheRoot: cacheRoot,
      hostAbi: Abi.linuxArm64,
    );
    expect(cache.vmSnapshotData, startsWith(cacheRoot));
    expect(p.basename(p.dirname(cache.vmSnapshotData)), 'linux-arm64');
  });

  test('uses per-user cache when SDK artifacts are absent', () {
    final cache = IosEngineCache(
      flutterRoot: flutterRoot,
      cacheRoot: cacheRoot,
    );
    final userEngineRoot = p.join(
      cacheRoot,
      'engine-hash',
      'artifacts',
      'engine',
    );

    expect(
      cache.flutterXcframework,
      p.join(userEngineRoot, 'ios', 'Flutter.xcframework'),
    );
    expect(
      cache.patchedSdkRoot,
      p.join(userEngineRoot, 'common', 'flutter_patched_sdk'),
    );
    expect(cache.vmSnapshotData, contains(userEngineRoot));
    expect(cache.isolateSnapshotData, contains(userEngineRoot));
  });

  test('prefers artifacts already present in Flutter SDK', () {
    final flutterSdkEngineRoot = p.join(
      flutterRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
    );
    Directory(
      p.join(flutterSdkEngineRoot, 'ios', 'Flutter.xcframework'),
    ).createSync(recursive: true);
    Directory(
      p.join(flutterSdkEngineRoot, 'common', 'flutter_patched_sdk'),
    ).createSync(recursive: true);

    final cache = IosEngineCache(
      flutterRoot: flutterRoot,
      cacheRoot: cacheRoot,
    );

    expect(
      cache.flutterXcframework,
      p.join(flutterSdkEngineRoot, 'ios', 'Flutter.xcframework'),
    );
    expect(
      cache.patchedSdkRoot,
      p.join(flutterSdkEngineRoot, 'common', 'flutter_patched_sdk'),
    );
  });
}
