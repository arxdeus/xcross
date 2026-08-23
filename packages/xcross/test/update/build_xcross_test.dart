import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/build_xcross.dart';

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
  }

  setUp(() => sandbox = Directory.systemTemp.createTempSync('xcross-build-'));
  tearDown(() => sandbox.deleteSync(recursive: true));

  test('embeds decoded ref identity only while the build runs', () async {
    seed();
    final original = File(generatedPath).readAsStringSync();
    String? generatedDuringBuild;

    final result = await buildXcross(
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
        packageRoot: sandbox,
        encodedVersion: Uri.encodeComponent('feature/throw'),
        released: false,
        runBuild: (executable, arguments, {required workingDirectory}) async {
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
      seed(pubspecVersion: '1.2.1');
      final original = File(generatedPath).readAsStringSync();

      await expectLater(
        () => buildXcross(
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
      seed(pubspecVersion: '1.2.1');
      final original = File(generatedPath).readAsStringSync();
      String? generatedDuringBuild;

      final result = await buildXcross(
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
