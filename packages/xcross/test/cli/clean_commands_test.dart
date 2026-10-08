import 'dart:io';

import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/composition/cli/runner.dart';
import 'package:xcross/src/shared/cli/basic/sdk_command.dart';
import 'package:xcross/src/shared/cli/compose/compose_clean_command.dart';
import 'package:xcross/src/shared/cli/flutter/subcommands/flutter_clean_command.dart';
import 'package:xcross/src/shared/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

import '../log_fixture.dart';
import 'runtime_fixture.dart';
import 'sdk_test_support.dart';

Directory _temp(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  final host = testRuntime().host;
  final policies = <FlutterTargetBuildPolicy>[
    IPhoneFlutterTarget(IPhoneTarget(host)),
    SimulatorFlutterTarget(SimulatorTarget(host)),
  ];

  group('registration', () {
    final runner = XcrossCli.buildRunner(
      testApplication(),
      configTerminal: TestTerminal(),
    );

    test('there is no top-level clean command', () {
      expect(runner.commands.keys, isNot(contains('clean')));
    });

    for (final parent in ['flutter', 'compose', 'sdk']) {
      test('$parent clean is registered', () {
        expect(runner.commands[parent]!.subcommands.keys, contains('clean'));
      });
    }
  });

  group('xcross flutter clean', () {
    test('removes device and simulator native assets and SwiftPM '
        'workspaces', () async {
      final project = _temp('xcross_clean_project');
      final cache = _temp('xcross_clean_cache');
      final env = {'XCROSS_CACHE_DIR': cache.path};
      final created = <Directory>[];
      for (final policy in policies) {
        created
          ..add(
            Directory(
              policy.buildDirectory(project.path, 'xcross-native-assets'),
            )..createSync(recursive: true),
          )
          ..add(
            Directory(
              SwiftPmWorkspace.forProject(
                project.path,
                policy: policy,
                environment: env,
              ).root,
            )..createSync(recursive: true),
          );
      }

      await FlutterCleanCommand.cleanProject(
        project.path,
        policies: policies,
        log: testLog(),
        environment: env,
      );

      for (final directory in created) {
        expect(directory.existsSync(), isFalse, reason: directory.path);
      }
    });

    test(
      'preserves unrelated build output and shared SwiftPM caches',
      () async {
        final project = _temp('xcross_clean_project');
        final cache = _temp('xcross_clean_cache');
        final unrelated = File(p.join(project.path, 'build', 'keep.txt'))
          ..createSync(recursive: true);
        final shared = File(
          p.join(cache.path, 'swiftpm', 'binary-artifacts-v1', 'keep.txt'),
        )..createSync(recursive: true);

        await FlutterCleanCommand.cleanProject(
          project.path,
          policies: policies,
          log: testLog(),
          environment: {'XCROSS_CACHE_DIR': cache.path},
        );

        expect(unrelated.existsSync(), isTrue);
        expect(shared.existsSync(), isTrue);
      },
    );

    test('succeeds when project caches do not exist', () async {
      final project = _temp('xcross_clean_project');
      final cache = _temp('xcross_clean_cache');
      final env = {'XCROSS_CACHE_DIR': cache.path};
      for (var i = 0; i < 2; i++) {
        expect(
          await FlutterCleanCommand.cleanProject(
            project.path,
            policies: policies,
            log: testLog(),
            environment: env,
          ),
          isEmpty,
        );
      }
    });
  });

  group('xcross compose clean', () {
    Future<List<String>> clean(String root) => ComposeCleanCommand(
      host: host,
      log: testLog(),
      projectRoot: root,
    ).cleanProject();

    test('removes xcross build output and runner objects', () async {
      final project = _temp('xcross_compose_clean');
      final directories = [
        p.join(project.path, 'build', 'xcross-ios', 'konan-caches'),
        p.join(project.path, 'build', 'xcross-ios-simulator', 'runner'),
        p.join(project.path, 'build', 'xcross-compose', 'Runner'),
        p.join(project.path, 'iosApp', '.build', 'runner'),
      ];
      for (final path in directories) {
        Directory(path).createSync(recursive: true);
      }

      expect(await clean(project.path), hasLength(4));
      for (final path in directories) {
        expect(Directory(path).existsSync(), isFalse, reason: path);
      }
    });

    test('preserves Gradle output and iOS app sources', () async {
      final project = _temp('xcross_compose_clean');
      final keep = [
        File(p.join(project.path, 'composeApp', 'build', 'bin', 'keep.txt')),
        File(p.join(project.path, 'build', 'keep.txt')),
        File(p.join(project.path, 'iosApp', 'iosApp', 'App.swift')),
      ];
      for (final file in keep) {
        file.createSync(recursive: true);
      }
      Directory(
        p.join(project.path, 'build', 'xcross-ios'),
      ).createSync(recursive: true);

      await clean(project.path);

      for (final file in keep) {
        expect(file.existsSync(), isTrue, reason: file.path);
      }
    });

    test('succeeds when nothing was built', () async {
      final project = _temp('xcross_compose_clean');
      expect(await clean(project.path), isEmpty);
    });
  });

  group('xcross sdk clean', () {
    final sdkContext = SdkTestContext();
    tearDownAll(sdkContext.close);
    final command = SdkCleanCommand(sdkContext.installer());

    test('removes the SDK, its backup, and staging leftovers', () async {
      final root = _temp('xcross_sdk_clean');
      final dest = p.join(root.path, 'xcross-darwin.artifactbundle');
      Directory(p.join(dest, 'Developer')).createSync(recursive: true);
      Directory('$dest.previous').createSync();
      Directory('$dest.staging-abc123').createSync();
      final sibling = Directory(p.join(root.path, 'other.artifactbundle'))
        ..createSync();

      final removed = await command.cleanSdk(dest);

      expect(
        removed,
        unorderedEquals([dest, '$dest.previous', '$dest.staging-abc123']),
      );
      expect(Directory(dest).existsSync(), isFalse);
      expect(Directory('$dest.previous').existsSync(), isFalse);
      expect(Directory('$dest.staging-abc123').existsSync(), isFalse);
      expect(sibling.existsSync(), isTrue);
    });

    test('succeeds when no SDK is installed', () async {
      final root = _temp('xcross_sdk_clean');
      final dest = p.join(root.path, 'missing', 'xcross-darwin.artifactbundle');
      expect(await command.cleanSdk(dest), isEmpty);
    });
  });
}
