import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';

void main() {
  late Directory tmp;
  late String flutterRoot;
  late String cacheRoot;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_ios_engine_cache-');
    flutterRoot = p.join(tmp.path, 'flutter');
    cacheRoot = p.join(tmp.path, 'cache');
    final internal = Directory(p.join(flutterRoot, 'bin', 'internal'));
    await internal.create(recursive: true);
    await File(
      p.join(internal.path, 'engine.version'),
    ).writeAsString('engine-hash\n');
  });

  tearDown(() => tmp.delete(recursive: true));

  test('uses per-user cache when SDK artifacts are absent', () {
    final cache = IosEngineCache(
      flutterRoot: flutterRoot,
      cacheRoot: cacheRoot,
    );
    final engineRoot = p.join(cacheRoot, 'engine-hash', 'artifacts', 'engine');

    expect(
      cache.flutterXcframework,
      p.join(engineRoot, 'ios', 'Flutter.xcframework'),
    );
    expect(
      cache.patchedSdkRoot,
      p.join(engineRoot, 'common', 'flutter_patched_sdk'),
    );
    expect(cache.vmSnapshotData, contains(engineRoot));
    expect(cache.isolateSnapshotData, contains(engineRoot));
  });

  test('prefers artifacts already present in Flutter SDK', () {
    final sdkEngine = p.join(
      flutterRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
    );
    Directory(
      p.join(sdkEngine, 'ios', 'Flutter.xcframework'),
    ).createSync(recursive: true);
    Directory(
      p.join(sdkEngine, 'common', 'flutter_patched_sdk'),
    ).createSync(recursive: true);

    final cache = IosEngineCache(
      flutterRoot: flutterRoot,
      cacheRoot: cacheRoot,
    );

    expect(
      cache.flutterXcframework,
      p.join(sdkEngine, 'ios', 'Flutter.xcframework'),
    );
    expect(
      cache.patchedSdkRoot,
      p.join(sdkEngine, 'common', 'flutter_patched_sdk'),
    );
  });
}
