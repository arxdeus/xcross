import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/compose/compose.dart';
import 'package:xcross/src/errors.dart';

void main() {
  test(
    'assembles clean app bundle with runner plist framework and executable bits',
    () async {
      final fixture = _Fixture.create()..createInputs();
      final stale = Directory(
        p.join(fixture.root, 'build', 'xcross-ios', 'Example.app'),
      )..createSync(recursive: true);
      File(p.join(stale.path, 'stale.txt')).writeAsStringSync('stale');
      addTearDown(fixture.dispose);

      final appPath = await ComposeAppAssembler.assemble(
        project: fixture.project,
        runnerPath: fixture.runnerPath,
        frameworkPath: fixture.frameworkPath,
      );

      expect(
        appPath,
        p.join(fixture.root, 'build', 'xcross-ios', 'Example.app'),
      );
      expect(File(p.join(appPath, 'stale.txt')).existsSync(), isFalse);
      expect(File(p.join(appPath, 'Runner')).readAsStringSync(), 'runner');
      expect(
        File(
          p.join(appPath, 'Frameworks', 'Shared.framework', 'Shared'),
        ).readAsStringSync(),
        'framework',
      );
      expect(
        File(
          p.join(
            appPath,
            'Frameworks',
            'Shared.framework',
            'Headers',
            'Shared.h',
          ),
        ).readAsStringSync(),
        'header',
      );
      expect(
        File(
          p.join(appPath, 'Frameworks', 'Shared.framework', 'link'),
        ).existsSync(),
        isFalse,
      );
      final plist =
          PropertyListSerialization.propertyListWithString(
                File(p.join(appPath, 'Info.plist')).readAsStringSync(),
              )
              as Map;
      expect(plist['CFBundleExecutable'], 'Runner');
      if (!Platform.isWindows) {
        expect(
          FileStat.statSync(p.join(appPath, 'Runner')).mode & 0x49,
          isNonZero,
        );
        expect(
          FileStat.statSync(
                p.join(appPath, 'Frameworks', 'Shared.framework', 'Shared'),
              ).mode &
              0x49,
          isNonZero,
        );
      }
    },
  );

  test('rejects missing runner and framework inputs', () async {
    final fixture = _Fixture.create()..createInputs();
    addTearDown(fixture.dispose);

    await expectLater(
      ComposeAppAssembler.assemble(
        project: fixture.project,
        runnerPath: p.join(fixture.root, 'missing-runner'),
        frameworkPath: fixture.frameworkPath,
      ),
      throwsA(isA<XcrossError>()),
    );
    await expectLater(
      ComposeAppAssembler.assemble(
        project: fixture.project,
        runnerPath: fixture.runnerPath,
        frameworkPath: p.join(fixture.root, 'Missing.framework'),
      ),
      throwsA(isA<XcrossError>()),
    );
  });
}

final class _Fixture {
  _Fixture._(this.temp)
    : root = temp.path,
      runnerPath = p.join(temp.path, 'runner', 'Runner'),
      frameworkPath = p.join(temp.path, 'Shared.framework');

  factory _Fixture.create() => _Fixture._(
    Directory.systemTemp.createTempSync('xcross_app_assembler_test_'),
  );

  final Directory temp;
  final String root;
  final String runnerPath;
  final String frameworkPath;

  KmpProject get project => KmpProject(
    root: root,
    modulePath: p.join(root, 'shared'),
    moduleName: 'shared',
    baseName: 'Shared',
    entryKind: KmpEntryKind.swiftApp,
    bundleId: 'dev.example.shared',
    appName: 'Example',
  );

  void createInputs() {
    File(runnerPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('runner');
    Directory(p.join(frameworkPath, 'Headers')).createSync(recursive: true);
    File(p.join(frameworkPath, 'Shared')).writeAsStringSync('framework');
    File(
      p.join(frameworkPath, 'Headers', 'Shared.h'),
    ).writeAsStringSync('header');
    if (!Platform.isWindows) {
      Link(
        p.join(frameworkPath, 'link'),
      ).createSync(p.join(frameworkPath, 'Shared'));
    }
  }

  Future<void> dispose() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  }
}
