import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/flutter_packer.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/models/flutter/dart_defines.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';

import 'flutter_test_log.dart';
import 'flutter_test_runtime.dart';

void main() {
  group('DartDefines.resolve', () {
    test('appends framework defines after user defines, in flutter order', () {
      expect(
        DartDefines.resolve(
          const ['USER=1', 'OTHER=2'],
          flavor: 'staging',
          buildName: '1.2.3',
          buildNumber: '4',
          versionDefines: const ['FLUTTER_VERSION=3.47.0'],
        ),
        [
          'USER=1',
          'OTHER=2',
          'FLUTTER_APP_FLAVOR=staging',
          'FLUTTER_BUILD_NAME=1.2.3',
          'FLUTTER_BUILD_NUMBER=4',
          'FLUTTER_VERSION=3.47.0',
        ],
      );
    });

    test('omits absent values', () {
      expect(DartDefines.resolve(const ['USER=1']), ['USER=1']);
    });

    test('an explicit FLUTTER_APP_FLAVOR define wins over --flavor', () {
      expect(
        DartDefines.resolve(const [
          'FLUTTER_APP_FLAVOR=explicit',
        ], flavor: 'staging'),
        ['FLUTTER_APP_FLAVOR=explicit'],
      );
    });

    Matcher rejects(String message) => throwsA(
      isA<FlutterBuildError>().having((e) => e.message, 'message', message),
    );

    for (final key in ['FLUTTER_BUILD_NAME', 'FLUTTER_BUILD_NUMBER']) {
      test('rejects a user-set $key', () {
        for (final define in ['$key=1', key]) {
          expect(
            () => DartDefines.resolve([define]),
            rejects(
              '$key is used by the framework and cannot be set using '
              '--dart-define or --dart-define-from-file',
            ),
          );
        }
      });

      test('rejects $key set in the environment', () {
        expect(
          () => DartDefines.resolve(
            const [],
            environment: (name) => name == key ? '1' : null,
          ),
          rejects(
            '$key is used by the framework and cannot be set in the '
            'environment.',
          ),
        );
      });
    }

    for (final key in DartDefines.versionKeys) {
      test('rejects a user-set $key', () {
        expect(
          () => DartDefines.resolve(['$key=x']),
          rejects(
            '$key is used by the framework and cannot be set using '
            '--dart-define or --dart-define-from-file. Use FlutterVersion '
            'to access it in Flutter code',
          ),
        );
      });
    }

    test('rejects a user-set FLUTTER_ENABLED_FEATURE_FLAGS', () {
      expect(
        () => DartDefines.resolve(const ['FLUTTER_ENABLED_FEATURE_FLAGS=x']),
        throwsA(isA<FlutterBuildError>()),
      );
    });
  });

  group('FlutterBuildContext.dartDefines', testOn: '!windows', () {
    late Directory project;
    late Directory flutter;
    setUp(() {
      project = Directory.systemTemp.createTempSync('xcross_defines_project_');
      flutter = Directory.systemTemp.createTempSync('xcross_defines_flutter_');
      File(p.join(flutter.path, 'bin', 'cache', 'flutter.version.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'frameworkVersion': '3.47.0',
            'channel': 'stable',
            'repositoryUrl': 'https://github.com/flutter/flutter.git',
            'frameworkRevision': '4cf24164269a5ebf0c16a028a00727d0e77bbb05',
            'engineRevision': '5f77625673248ee5846fbcaf5d3e1a3878386fd7',
            'dartSdkVersion': '3.13.0',
          }),
        );
    });
    tearDown(() {
      project.deleteSync(recursive: true);
      flutter.deleteSync(recursive: true);
    });

    FlutterBuildContext contextFor(
      String version, {
      FlutterBuildOptions options = const FlutterBuildOptions(
        dartDefines: ['USER=1'],
        flavor: 'staging',
      ),
    }) {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: demo\nversion: $version\n');
      final packer = FlutterPacker(
        runtime: testIPhoneRuntime(),
        projectRoot: project.path,
        bundleId: 'com.example.demo',
        options: options,
      );
      return FlutterBuildContext(
        request: packer.request,
        flutterRoot: flutter.path,
      );
    }

    test('includes the pubspec version and the SDK version family', () {
      expect(contextFor('1.2.3+4').dartDefines, [
        'USER=1',
        'FLUTTER_APP_FLAVOR=staging',
        'FLUTTER_BUILD_NAME=1.2.3',
        'FLUTTER_BUILD_NUMBER=4',
        'FLUTTER_VERSION=3.47.0',
        'FLUTTER_CHANNEL=stable',
        'FLUTTER_GIT_URL=https://github.com/flutter/flutter.git',
        'FLUTTER_FRAMEWORK_REVISION=4cf2416426',
        'FLUTTER_ENGINE_REVISION=5f77625673',
        'FLUTTER_DART_VERSION=3.13.0',
      ]);
    });

    test('--build-name/--build-number override the pubspec', () {
      final defines = contextFor(
        '1.2.3+4',
        options: const FlutterBuildOptions(
          buildName: '9.0.0',
          buildNumber: '9',
        ),
      ).dartDefines;
      expect(defines.where((define) => define.startsWith('FLUTTER_BUILD_')), [
        'FLUTTER_BUILD_NAME=9.0.0',
        'FLUTTER_BUILD_NUMBER=9',
      ]);
    });

    test('an invalid pubspec version adds no build defines and one hint', () {
      final context = contextFor('1.0');
      expect(
        context.dartDefines.where((d) => d.startsWith('FLUTTER_BUILD_')),
        isEmpty,
      );
      final log = context.runtime.runner.log;
      final errors = (log.output as RecordingFlutterLogOutput).errors;
      expect(
        errors.where((message) => message.contains('Invalid version 1.0')),
        hasLength(1),
      );
    });
  });
}
