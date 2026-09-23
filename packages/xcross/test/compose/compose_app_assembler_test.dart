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

  test('static framework is linked in, not embedded in the bundle', () async {
    final fixture = _Fixture.create()..createInputs();
    addTearDown(fixture.dispose);

    final appPath = await ComposeAppAssembler.withSeams().assemble(
      project: fixture.staticProject,
      runnerPath: fixture.runnerPath,
      frameworkPath: fixture.frameworkPath,
    );

    expect(File(p.join(appPath, 'Runner')).existsSync(), isTrue);
    expect(File(p.join(appPath, 'Info.plist')).existsSync(), isTrue);
    // A static framework's code is inside Runner; copying the archive in would
    // ship hundreds of megabytes of dead weight and break the signing layout.
    expect(Directory(p.join(appPath, 'Frameworks')).existsSync(), isFalse);
  });

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

  test(
    'preserves prior app and cleans staging debris when framework copy fails',
    () async {
      final fixture = _Fixture.create()..createInputs();
      final previousApp = fixture.createPreviousApp();
      addTearDown(fixture.dispose);

      await expectLater(
        ComposeAppAssembler.withSeams(
          copyDirectory: (source, destination) {
            throw const FileSystemException('copy failed');
          },
        ).assemble(
          project: fixture.project,
          runnerPath: fixture.runnerPath,
          frameworkPath: fixture.frameworkPath,
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(
        File(p.join(previousApp, 'Runner')).readAsStringSync(),
        'old-runner',
      );
      expect(
        File(p.join(previousApp, 'Info.plist')).readAsStringSync(),
        'old-plist',
      );
      expect(
        Directory(
          p.dirname(previousApp),
        ).listSync(followLinks: false).map((entity) => p.basename(entity.path)),
        everyElement(isNot(anyOf(contains('.staging'), contains('.backup')))),
      );
    },
  );

  test('successful assembly replaces stale output through staging', () async {
    final fixture = _Fixture.create()..createInputs();
    final previousApp = fixture.createPreviousApp();
    addTearDown(fixture.dispose);

    final appPath = await ComposeAppAssembler.withSeams().assemble(
      project: fixture.project,
      runnerPath: fixture.runnerPath,
      frameworkPath: fixture.frameworkPath,
    );

    expect(appPath, previousApp);
    expect(File(p.join(appPath, 'Runner')).readAsStringSync(), 'runner');
    expect(
      File(p.join(appPath, 'Info.plist')).readAsStringSync(),
      isNot('old-plist'),
    );
    expect(File(p.join(appPath, 'old-only.txt')).existsSync(), isFalse);
    expect(
      Directory(
        p.dirname(appPath),
      ).listSync(followLinks: false).map((entity) => p.basename(entity.path)),
      everyElement(isNot(anyOf(contains('.staging'), contains('.backup')))),
    );
  });

  test(
    'install rename failure restores previous app and removes backup container',
    () async {
      final fixture = _Fixture.create()..createInputs();
      final previousApp = fixture.createPreviousApp();
      var failedInstall = false;
      addTearDown(fixture.dispose);

      await expectLater(
        ComposeAppAssembler.withSeams(
          renameDirectory: (source, newPath) {
            if (!failedInstall &&
                newPath == previousApp &&
                source.path != previousApp) {
              failedInstall = true;
              throw const FileSystemException('install failed');
            }
            return source.rename(newPath);
          },
        ).assemble(
          project: fixture.project,
          runnerPath: fixture.runnerPath,
          frameworkPath: fixture.frameworkPath,
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(failedInstall, isTrue);
      expect(
        File(p.join(previousApp, 'Runner')).readAsStringSync(),
        'old-runner',
      );
      expect(
        fixture.outputDirNames(),
        everyElement(isNot(contains('.backup'))),
      );
      expect(
        fixture.outputDirNames(),
        everyElement(isNot(contains('.staging'))),
      );
    },
  );

  test(
    'restore failure preserves backup container and reports its path',
    () async {
      final fixture = _Fixture.create()..createInputs();
      final previousApp = fixture.createPreviousApp();
      var installFailed = false;
      addTearDown(fixture.dispose);

      await expectLater(
        ComposeAppAssembler.withSeams(
          renameDirectory: (source, newPath) {
            if (newPath == previousApp && source.path != previousApp) {
              if (!installFailed) {
                installFailed = true;
                throw const FileSystemException('install failed');
              }
              throw const FileSystemException('restore failed');
            }
            return source.rename(newPath);
          },
        ).assemble(
          project: fixture.project,
          runnerPath: fixture.runnerPath,
          frameworkPath: fixture.frameworkPath,
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('restore failed'), contains('.backup')),
          ),
        ),
      );

      final backups = fixture.outputDirNames().where(
        (name) => name.contains('.backup'),
      );
      expect(backups, hasLength(1));
      final backupContainer = p.join(fixture.outputDir, backups.single);
      expect(
        File(
          p.join(backupContainer, 'Example.app', 'Runner'),
        ).readAsStringSync(),
        'old-runner',
      );
      expect(
        fixture.outputDirNames(),
        everyElement(isNot(contains('.staging'))),
      );
    },
  );

  test("copies the built target's Compose resources into the bundle", () async {
    final fixture = _Fixture.create();
    // The framework path names the target, and only that target's resources are
    // staged — the simulator's set would be dead weight in a device bundle.
    final deviceFramework = fixture.frameworkPathFor('iosArm64');
    fixture.createInputsAt(deviceFramework);
    fixture.createResources(
      'kotlin-multiplatform-resources/aggregated-resources/iosArm64/'
      'composeResources',
      {'com.example.app.resources/font/worksans_regular.ttf': 'device-font'},
    );
    fixture.createResources(
      'kotlin-multiplatform-resources/aggregated-resources/'
      'iosSimulatorArm64/composeResources',
      {'com.example.app.resources/font/worksans_regular.ttf': 'sim-font'},
    );
    addTearDown(fixture.dispose);

    final appPath = await ComposeAppAssembler.withSeams().assemble(
      project: fixture.project,
      runnerPath: fixture.runnerPath,
      frameworkPath: deviceFramework,
    );

    // Compose reads resources from the main bundle; without this directory the
    // first composition that loads a font throws MissingResourceException.
    expect(
      File(
        p.join(
          appPath,
          'compose-resources',
          'composeResources',
          'com.example.app.resources',
          'font',
          'worksans_regular.ttf',
        ),
      ).readAsStringSync(),
      'device-font',
    );
  });

  test(
    "prefers aggregated resources over the module's processed ones",
    () async {
      final fixture = _Fixture.create();
      final deviceFramework = fixture.frameworkPathFor('iosArm64');
      fixture.createInputsAt(deviceFramework);
      fixture.createResources(
        'kotlin-multiplatform-resources/aggregated-resources/iosArm64/'
        'composeResources',
        {
          'com.example.app.resources/font/worksans_regular.ttf': 'aggregated',
          // Contributed by a dependency, so only the aggregated tree has it.
          'io.coil_kt.coil3.coil_compose_core.generated.resources/coil.txt':
              'coil',
        },
      );
      fixture.createResources(
        'processedResources/iosArm64/main/composeResources',
        {'com.example.app.resources/font/worksans_regular.ttf': 'processed'},
      );
      addTearDown(fixture.dispose);

      final appPath = await ComposeAppAssembler.withSeams().assemble(
        project: fixture.project,
        runnerPath: fixture.runnerPath,
        frameworkPath: deviceFramework,
      );

      expect(
        File(
          p.join(
            appPath,
            'compose-resources',
            'composeResources',
            'com.example.app.resources',
            'font',
            'worksans_regular.ttf',
          ),
        ).readAsStringSync(),
        'aggregated',
      );
      expect(
        File(
          p.join(
            appPath,
            'compose-resources',
            'composeResources',
            'io.coil_kt.coil3.coil_compose_core.generated.resources',
            'coil.txt',
          ),
        ).existsSync(),
        isTrue,
      );
    },
  );

  test(
    'adds no compose-resources directory to a project without them',
    () async {
      final fixture = _Fixture.create()..createInputs();
      addTearDown(fixture.dispose);

      final appPath = await ComposeAppAssembler.withSeams().assemble(
        project: fixture.project,
        runnerPath: fixture.runnerPath,
        frameworkPath: fixture.frameworkPath,
      );

      expect(
        Directory(p.join(appPath, 'compose-resources')).existsSync(),
        isFalse,
      );
    },
  );

  // Staging nothing is correct for a project with no resources and wrong for a
  // project whose resources were simply not found: that bundle throws
  // MissingResourceException on the first resource it reads, with nothing in
  // the build log pointing back here. `Log` writes to the process's own stderr,
  // so the warning is observed by running the assembler in a child process.
  test('warns when resources exist but their layout is unrecognised', () async {
    final fixture = _Fixture.create();
    final framework = fixture.frameworkPathFor('iosArm64');
    fixture.createInputsAt(framework);
    fixture.createResources('some-unknown-layout/composeResources', {
      'pkg/font.ttf': 'font',
    });
    addTearDown(fixture.dispose);

    final script = File(p.join(fixture.root, 'assemble.dart'))
      ..writeAsStringSync('''
import 'package:xcross/src/compose/compose.dart';

Future<void> main() async {
  await ComposeAppAssembler.withSeams().assemble(
    project: KmpProject(
      root: r'${fixture.root}',
      modulePath: r'${p.join(fixture.root, 'shared')}',
      moduleName: 'shared',
      baseName: 'Shared',
      entryKind: KmpEntryKind.swiftApp,
      bundleId: 'dev.example.shared',
      appName: 'Example',
    ),
    runnerPath: r'${fixture.runnerPath}',
    frameworkPath: r'$framework',
  );
}
''');
    final result = await Process.run(Platform.executable, [
      '--packages=${_packageConfig()}',
      script.path,
    ]);

    expect(result.stderr, contains('MissingResourceException'));
    expect(
      Directory(
        p.join(fixture.outputDir, 'Example.app', 'compose-resources'),
      ).existsSync(),
      isFalse,
      reason: 'the layout was not recognised, so nothing could be staged',
    );
  });
}

/// The workspace package config, so a child process can resolve `package:xcross`.
String _packageConfig() {
  var directory = Directory.current;
  while (true) {
    final candidate = File(
      p.join(directory.path, '.dart_tool', 'package_config.json'),
    );
    if (candidate.existsSync()) return candidate.path;
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('no .dart_tool/package_config.json above $directory');
    }
    directory = parent;
  }
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

  String get outputDir => p.join(root, 'build', 'xcross-ios');

  KmpProject get staticProject => KmpProject(
    root: root,
    modulePath: p.join(root, 'shared'),
    moduleName: 'shared',
    baseName: 'Shared',
    entryKind: KmpEntryKind.swiftApp,
    isStaticFramework: true,
    bundleId: 'dev.example.shared',
    appName: 'Example',
  );

  KmpProject get project => KmpProject(
    root: root,
    modulePath: p.join(root, 'shared'),
    moduleName: 'shared',
    baseName: 'Shared',
    entryKind: KmpEntryKind.swiftApp,
    bundleId: 'dev.example.shared',
    appName: 'Example',
  );

  void createInputs() => createInputsAt(frameworkPath);

  void createInputsAt(String path) {
    File(runnerPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('runner');
    Directory(p.join(path, 'Headers')).createSync(recursive: true);
    File(p.join(path, 'Shared')).writeAsStringSync('framework');
    File(p.join(path, 'Headers', 'Shared.h')).writeAsStringSync('header');
    if (!Platform.isWindows) {
      Link(p.join(path, 'link')).createSync(p.join(path, 'Shared'));
    }
  }

  /// A framework path in the layout Gradle produces, e.g.
  /// `<root>/shared/build/bin/iosArm64/debugFramework/Shared.framework`.
  String frameworkPathFor(String target) => p.join(
    root,
    'shared',
    'build',
    'bin',
    target,
    'debugFramework',
    'Shared.framework',
  );

  /// Writes resource files under the module's build directory, at [relative].
  void createResources(String relative, Map<String, String> files) {
    for (final entry in files.entries) {
      final file = File(p.join(root, 'shared', 'build', relative, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
  }

  String createPreviousApp() {
    final appPath = p.join(outputDir, 'Example.app');
    Directory(appPath).createSync(recursive: true);
    File(p.join(appPath, 'Runner')).writeAsStringSync('old-runner');
    File(p.join(appPath, 'Info.plist')).writeAsStringSync('old-plist');
    File(p.join(appPath, 'old-only.txt')).writeAsStringSync('old');
    return appPath;
  }

  Iterable<String> outputDirNames() => Directory(
    outputDir,
  ).listSync(followLinks: false).map((entity) => p.basename(entity.path));

  Future<void> dispose() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  }
}
