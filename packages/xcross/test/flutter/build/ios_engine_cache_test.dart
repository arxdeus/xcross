import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';

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
