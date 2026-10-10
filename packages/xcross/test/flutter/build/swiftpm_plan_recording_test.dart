import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/windows_swift_plan_repair.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';

import 'swiftpm_test_context.dart';

final _runtime = testWindowsSwiftPmRuntime();

String _tool(Directory root, String body) {
  final file = File(p.join(root.path, 'tool'))
    ..writeAsStringSync('#!/bin/sh\necho "\$@" >> "${root.path}/calls"\n$body');
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

List<String> _calls(Directory root) {
  final file = File(p.join(root.path, 'calls'));
  return file.existsSync() ? file.readAsLinesSync() : const [];
}

void main() {
  test(
    'records a plan through an absent target so the next build reuses it',
    () async {
      final root = await Directory.systemTemp.createTemp('xcross-plan-');
      addTearDown(() => root.delete(recursive: true));
      final tool = _tool(
        root,
        'echo "error: no target named \'${SwiftPmBuildPlan.planOnlyTarget}\'" >&2\n'
        'exit 1\n',
      );
      await _runtime.buildPlan.recordPlan(
        tool,
        const ['--scratch-path', 'scratch'],
        environment: const {},
        label: 'plan',
      );
      expect(_calls(root), [
        '--scratch-path scratch --target ${SwiftPmBuildPlan.planOnlyTarget}',
      ]);
    },
    skip: Platform.isWindows,
  );

  test('surfaces planning failures other than the absent target', () async {
    final root = await Directory.systemTemp.createTemp('xcross-plan-');
    addTearDown(() => root.delete(recursive: true));
    final tool = _tool(root, 'echo "error: manifest parse" >&2\nexit 1\n');
    await expectLater(
      _runtime.buildPlan.recordPlan(
        tool,
        const [],
        environment: const {},
        label: 'plan',
      ),
      throwsA(
        isA<FlutterBuildError>().having(
          (error) => error.message,
          'message',
          contains('manifest parse'),
        ),
      ),
    );
  }, skip: Platform.isWindows);

  test('a succeeding first build runs once without the repair retry', () async {
    final root = await Directory.systemTemp.createTemp('xcross-build-');
    addTearDown(() => root.delete(recursive: true));
    final scratch = Directory(p.join(root.path, 'scratch'))..createSync();
    final targetBuildDir = Directory(
      p.join(scratch.path, 'arm64-apple-ios', 'debug'),
    )..createSync(recursive: true);
    final tool = _tool(root, 'exit 0\n');
    final execution = WindowsSwiftPmBuildExecution(
      runner: _runtime.runner,
      repair: WindowsSwiftPlanRepair(_runtime.runner),
      consumerRepair: _runtime.consumerRepair,
    );
    await execution.executeCommand(
      SwiftPmBuildCommand(
        executable: tool,
        arguments: const ['--target', 'Layer'],
        environment: const {},
        scratchPath: scratch.path,
        targetBuildDir: targetBuildDir.path,
        consumerProducts: const {},
      ),
    );
    expect(_calls(root), ['--target Layer']);
  }, skip: Platform.isWindows);

  group('Clang module cache race', _moduleCacheRaceTests);
}

/// Windows builds run without implicit module locks, so parallel frontends
/// occasionally collide on one SDK `.pcm` and fail a build that passes when
/// re-run.
void _moduleCacheRaceTests() {
  const lostOutput =
      '<unknown>:0: error: unable to open output file '
      r"'C:\scratch\debug\ModuleCache\34YQOH10T1LVD\ImageIO-Z37NX9KCVC6W.pcm': "
      "'operation not permitted'";
  const duplicated =
      "<unknown>:0: error: module 'UIKit' is defined in both "
      r"'C:\scratch\ModuleCache\34YQOH10T1LVD\UIKit-1D0IXTMURHS36.pcm' and "
      r"'C:\scratch\ModuleCache\34YQOH10T1LVD\UIKit-1D0IXTMURHS36.pcm'";

  test('recognizes the Clang module cache races seen on Windows', () {
    for (final error in [lostOutput, duplicated]) {
      expect(
        WindowsSwiftPmBuildExecution.isModuleCacheRace(error),
        isTrue,
        reason: error,
      );
    }
  });

  test('leaves genuine compile errors and timeouts alone', () {
    const observed = [
      "error: could not build Objective-C module 'UIKit'",
      "error: no such module '_SentryPrivate'",
      r"error: unable to open output file 'C:\out\Foo.o': 'operation not permitted'",
      'command timed out after 3600s and was killed\n$lostOutput',
    ];
    for (final error in observed) {
      expect(
        WindowsSwiftPmBuildExecution.isModuleCacheRace(error),
        isFalse,
        reason: error,
      );
    }
  });

  Future<
    ({Directory root, Directory targetBuildDir, SwiftPmBuildCommand command})
  >
  fixtureFor(String body) async {
    final root = await Directory.systemTemp.createTemp('xcross-race-');
    addTearDown(() => root.delete(recursive: true));
    final scratch = Directory(p.join(root.path, 'scratch'))..createSync();
    final targetBuildDir = Directory(
      p.join(scratch.path, 'arm64-apple-ios', 'debug'),
    )..createSync(recursive: true);
    return (
      root: root,
      targetBuildDir: targetBuildDir,
      command: SwiftPmBuildCommand(
        executable: _tool(root, body),
        arguments: const ['--target', 'Layer'],
        environment: const {},
        scratchPath: scratch.path,
        targetBuildDir: targetBuildDir.path,
        consumerProducts: const {},
      ),
    );
  }

  WindowsSwiftPmBuildExecution execution() => WindowsSwiftPmBuildExecution(
    runner: _runtime.runner,
    repair: WindowsSwiftPlanRepair(_runtime.runner),
    consumerRepair: _runtime.consumerRepair,
  );

  test(
    'clears the module cache and retries a build that lost the race',
    () async {
      // Fails the first time only, the way the CI race does.
      final fixture = await fixtureFor(
        'if [ ! -f "\$(dirname "\$0")/raced" ]; then\n'
        '  touch "\$(dirname "\$0")/raced"\n'
        "  cat >&2 <<'MSG'\n$lostOutput\nMSG\n"
        '  exit 1\n'
        'fi\n'
        'exit 0\n',
      );
      final stale = File(
        p.join(fixture.targetBuildDir.path, 'ModuleCache', 'X', 'ImageIO.pcm'),
      )..createSync(recursive: true);
      await execution().executeCommand(fixture.command);
      expect(_calls(fixture.root), ['--target Layer', '--target Layer']);
      expect(stale.existsSync(), isFalse);
    },
    skip: Platform.isWindows,
  );

  test('gives up after the configured number of races', () async {
    final fixture = await fixtureFor(
      "cat >&2 <<'MSG'\n$duplicated\nMSG\nexit 1\n",
    );
    await expectLater(
      execution().executeCommand(fixture.command),
      throwsA(anything),
    );
    expect(_calls(fixture.root), List.filled(3, '--target Layer'));
  }, skip: Platform.isWindows);

  test('does not retry a genuine compile error', () async {
    final fixture = await fixtureFor(
      "echo \"error: no such module '_SentryPrivate'\" >&2\nexit 1\n",
    );
    await expectLater(
      execution().executeCommand(fixture.command),
      throwsA(anything),
    );
    expect(_calls(fixture.root), ['--target Layer']);
  }, skip: Platform.isWindows);
}
