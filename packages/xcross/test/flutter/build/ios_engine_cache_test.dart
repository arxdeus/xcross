import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('xcross_engine_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('accepts only complete artifacts stamped for the engine revision', () {
    File(
      p.join(tmp.path, '.xcross-engine-revision'),
    ).writeAsStringSync('abc\n');
    File(p.join(tmp.path, 'snapshot.bin')).writeAsStringSync('snapshot');
    Directory(p.join(tmp.path, 'Flutter.xcframework')).createSync();

    expect(
      IosEngineCache.artifactIsCurrent(
        directory: tmp.path,
        revision: 'abc',
        requiredFiles: const ['snapshot.bin'],
        requiredDirectories: const ['Flutter.xcframework'],
      ),
      isTrue,
    );
  });

  test('accepts complete Flutter-managed artifacts with an official stamp', () {
    final stamp = File(p.join(tmp.path, 'flutter_sdk.stamp'))
      ..writeAsStringSync('abc\n');
    File(p.join(tmp.path, 'snapshot.bin')).writeAsStringSync('snapshot');

    expect(
      IosEngineCache.artifactIsCurrent(
        directory: tmp.path,
        revision: 'abc',
        officialStamp: stamp.path,
        requiredFiles: const ['snapshot.bin'],
      ),
      isTrue,
    );
  });

  test('rejects artifacts without a revision stamp', () {
    File(p.join(tmp.path, 'snapshot.bin')).writeAsStringSync('snapshot');

    expect(
      IosEngineCache.artifactIsCurrent(
        directory: tmp.path,
        revision: 'abc',
        requiredFiles: const ['snapshot.bin'],
      ),
      isFalse,
    );
  });

  test('private stamp takes precedence over a newer official stamp', () {
    final official = File(p.join(tmp.path, 'flutter_sdk.stamp'))
      ..writeAsStringSync('new');
    File(p.join(tmp.path, '.xcross-engine-revision')).writeAsStringSync('old');
    File(p.join(tmp.path, 'snapshot.bin')).writeAsStringSync('snapshot');

    expect(
      IosEngineCache.artifactIsCurrent(
        directory: tmp.path,
        revision: 'new',
        officialStamp: official.path,
        requiredFiles: const ['snapshot.bin'],
      ),
      isFalse,
    );
  });

  test('rejects artifacts stamped for another engine revision', () {
    File(p.join(tmp.path, '.xcross-engine-revision')).writeAsStringSync('old');
    File(p.join(tmp.path, 'snapshot.bin')).writeAsStringSync('snapshot');

    expect(
      IosEngineCache.artifactIsCurrent(
        directory: tmp.path,
        revision: 'new',
        requiredFiles: const ['snapshot.bin'],
      ),
      isFalse,
    );
  });

  test('rejects empty required files', () {
    File(p.join(tmp.path, '.xcross-engine-revision')).writeAsStringSync('abc');
    File(p.join(tmp.path, 'snapshot.bin')).createSync();

    expect(
      IosEngineCache.artifactIsCurrent(
        directory: tmp.path,
        revision: 'abc',
        requiredFiles: const ['snapshot.bin'],
      ),
      isFalse,
    );
  });

  test('rejects stamped artifacts with missing payload', () {
    File(p.join(tmp.path, '.xcross-engine-revision')).writeAsStringSync('abc');

    expect(
      IosEngineCache.artifactIsCurrent(
        directory: tmp.path,
        revision: 'abc',
        requiredFiles: const ['snapshot.bin'],
      ),
      isFalse,
    );
  });
}
