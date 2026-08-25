import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_bundle_resources.dart';

void main() {
  late Directory tmp;
  late Directory project;
  late Directory runner;
  late Directory bundle;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ios_bundle_resources_test-');
    project = Directory(p.join(tmp.path, 'project'))..createSync();
    runner = Directory(p.join(project.path, 'ios', 'Runner'))
      ..createSync(recursive: true);
    bundle = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('copies compiled storyboard directories into the bundle', () async {
    final base = Directory(p.join(runner.path, 'Base.lproj'))..createSync();
    for (final name in ['LaunchScreen.storyboardc', 'Main.storyboardc']) {
      final storyboard = Directory(p.join(base.path, name))..createSync();
      File(p.join(storyboard.path, 'scene.nib')).writeAsStringSync(name);
    }

    await stageIosBundleResources(
      projectRoot: project.path,
      bundleDir: bundle.path,
    );

    for (final name in ['LaunchScreen.storyboardc', 'Main.storyboardc']) {
      expect(
        File(p.join(bundle.path, name, 'scene.nib')).readAsStringSync(),
        name,
      );
    }
  });

  test(
    'copies ios GoogleService-Info.plist when it is first existing',
    () async {
      File(
        p.join(project.path, 'ios', 'GoogleService-Info.plist'),
      ).writeAsStringSync('ios');

      await stageIosBundleResources(
        projectRoot: project.path,
        bundleDir: bundle.path,
      );

      expect(
        File(
          p.join(bundle.path, 'GoogleService-Info.plist'),
        ).readAsStringSync(),
        'ios',
      );
    },
  );

  test('prefers Runner GoogleService-Info.plist', () async {
    File(
      p.join(project.path, 'ios', 'GoogleService-Info.plist'),
    ).writeAsStringSync('ios');
    File(
      p.join(runner.path, 'GoogleService-Info.plist'),
    ).writeAsStringSync('runner');

    await stageIosBundleResources(
      projectRoot: project.path,
      bundleDir: bundle.path,
    );

    expect(
      File(p.join(bundle.path, 'GoogleService-Info.plist')).readAsStringSync(),
      'runner',
    );
  });
}
