import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
  late Directory temporary;
  late String output;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('native_asset_staging-');
    output = p.join(temporary.path, 'assemble');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test('staging isolates repairs from the original hook output', () async {
    final source = Directory(p.join(output, 'native_assets', 'Asset.framework'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'Asset')).writeAsStringSync('original');
    final staged = await stageNativeAssetFrameworks([source.path], output);
    expect(staged, [
      p.join(output, 'xcross_staged_frameworks', 'Asset.framework'),
    ]);
    File(p.join(staged.single, 'Asset')).writeAsStringSync('repaired');
    expect(File(p.join(source.path, 'Asset')).readAsStringSync(), 'original');
  });

  test('stages framework-relative links and rejects escaping links', () async {
    final source = Directory(
      p.join(output, 'native_assets', 'Versioned.framework'),
    );
    final versionA = Directory(p.join(source.path, 'Versions', 'A'))
      ..createSync(recursive: true);
    File(p.join(versionA.path, 'Versioned')).writeAsStringSync('original');
    try {
      Link(p.join(source.path, 'Versions', 'Current')).createSync('A');
      Link(
        p.join(source.path, 'Versioned'),
      ).createSync(p.join('Versions', 'Current', 'Versioned'));
    } on FileSystemException {
      markTestSkipped('host cannot create symlink fixtures');
      return;
    }
    final staged = await stageNativeAssetFrameworks([source.path], output);
    final stagedBinary = File(p.join(staged.single, 'Versioned'));
    expect(stagedBinary.readAsStringSync(), 'original');
    stagedBinary.writeAsStringSync('repaired');
    expect(
      File(p.join(versionA.path, 'Versioned')).readAsStringSync(),
      'original',
    );

    final outside = File(p.join(temporary.path, 'hook_output', 'Escaped'))
      ..createSync(recursive: true)
      ..writeAsStringSync('original');
    for (final (name, target) in [
      ('Relative', p.join('..', '..', '..', 'hook_output', 'Escaped')),
      ('Absolute', outside.path),
      ('Dangling', 'Missing'),
    ]) {
      final unsafe = Directory(
        p.join(output, 'native_assets', '$name.framework'),
      )..createSync(recursive: true);
      final link = Link(p.join(unsafe.path, name))..createSync(target);
      await expectLater(
        stageNativeAssetFrameworks([unsafe.path], output),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.message,
            'message',
            contains('Unsafe native asset framework symlink'),
          ),
        ),
      );
      link.deleteSync();
    }
    expect(outside.readAsStringSync(), 'original');
  });
}
