import 'dart:io';
import 'package:cli_kit/cli_kit.dart';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import '../../tool/build_xcross.dart';

import '../host_operations_fixtures.dart';

void main() {
  late Directory sandbox;
  late String generatedPath;

  void seed({
    String pubspecVersion = '1.2.1',
    String generatedSource =
        "part of 'version.dart';\n\nconst String _xcrossBuildVersion = 'unreleased';\nconst bool _xcrossBuildReleased = false;\n",
  }) {
    File(
      p.join(sandbox.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: xcross\nversion: $pubspecVersion\n');
    final lib = Directory(p.join(sandbox.path, 'lib', 'src'))
      ..createSync(recursive: true);
    generatedPath = p.join(lib.path, 'version.g.dart');
    File(generatedPath).writeAsStringSync(generatedSource);
    final builtBin = Directory(
      p.join(sandbox.path, 'build', 'cli', 'test', 'bundle', 'bin'),
    )..createSync(recursive: true);
    File(
      p.join(builtBin.path, Platform.isWindows ? 'xcross.exe' : 'xcross'),
    ).writeAsStringSync('');
    final xcrunBin = Directory(
      p.join(sandbox.path, 'build', 'xcrun', 'bundle', 'bin'),
    )..createSync(recursive: true);
    File(
      p.join(xcrunBin.path, Platform.isWindows ? 'xcrun.exe' : 'xcrun'),
    ).writeAsStringSync('');
  }

  setUp(() => sandbox = Directory.systemTemp.createTempSync('xcross-build-'));
  tearDown(() => sandbox.deleteSync(recursive: true));

  test('embeds decoded ref identity only while the build runs', () async {
    seed();
    final original = File(generatedPath).readAsStringSync();
    String? generatedDuringBuild;

    final result = await buildXcross(
      runner: ProcessRunner(LinuxHost(), log: fixtureLog()),
      dartExecutable: '/fixture/dart',
      packageRoot: sandbox,
      encodedVersion: Uri.encodeComponent('feature/a,b=c'),
      released: false,
      runBuild: (executable, arguments, {required workingDirectory}) async {
        generatedDuringBuild = File(generatedPath).readAsStringSync();
        return 0;
      },
    );

    expect(result, 0);
    expect(generatedDuringBuild, contains('"feature/a,b=c"'));
    expect(generatedDuringBuild, contains('false'));
    expect(File(generatedPath).readAsStringSync(), original);
  });

  test('restores the generated identity after a throwing runner', () async {
    seed();
    final original = File(generatedPath).readAsStringSync();

    await expectLater(
      () => buildXcross(
        runner: ProcessRunner(LinuxHost(), log: fixtureLog()),
        dartExecutable: '/fixture/dart',
        packageRoot: sandbox,
        encodedVersion: Uri.encodeComponent('feature/throw'),
        released: false,
        runBuild: (executable, arguments, {required workingDirectory}) {
          throw StateError('boom');
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(File(generatedPath).readAsStringSync(), original);
  });

  test('rejects a released non-semver identity', () async {
    seed();
    final original = File(generatedPath).readAsStringSync();

    await expectLater(
      () => buildXcross(
        runner: ProcessRunner(LinuxHost(), log: fixtureLog()),
        dartExecutable: '/fixture/dart',
        packageRoot: sandbox,
        encodedVersion: Uri.encodeComponent('feature/not-a-release'),
        released: true,
        runBuild: (executable, arguments, {required workingDirectory}) async =>
            0,
      ),
      throwsArgumentError,
    );

    expect(File(generatedPath).readAsStringSync(), original);
  });

  test(
    'rejects a released version whose core disagrees with pubspec.yaml',
    () async {
      seed();
      final original = File(generatedPath).readAsStringSync();

      await expectLater(
        () => buildXcross(
          runner: ProcessRunner(LinuxHost(), log: fixtureLog()),
          dartExecutable: '/fixture/dart',
          packageRoot: sandbox,
          encodedVersion: Uri.encodeComponent('2.0.0+1'),
          released: true,
          runBuild:
              (executable, arguments, {required workingDirectory}) async => 0,
        ),
        throwsArgumentError,
      );

      expect(File(generatedPath).readAsStringSync(), original);
    },
  );

  test(
    'normalizes a released v-prefixed tag to the pubspec core identity',
    () async {
      seed();
      final original = File(generatedPath).readAsStringSync();
      String? generatedDuringBuild;

      final result = await buildXcross(
        runner: ProcessRunner(LinuxHost(), log: fixtureLog()),
        dartExecutable: '/fixture/dart',
        packageRoot: sandbox,
        encodedVersion: Uri.encodeComponent('v1.2.1'),
        released: true,
        runBuild: (executable, arguments, {required workingDirectory}) async {
          generatedDuringBuild = File(generatedPath).readAsStringSync();
          return 0;
        },
      );

      expect(result, 0);
      expect(generatedDuringBuild, contains('"1.2.1"'));
      expect(generatedDuringBuild, contains('true'));
      expect(File(generatedPath).readAsStringSync(), original);
    },
  );
}
