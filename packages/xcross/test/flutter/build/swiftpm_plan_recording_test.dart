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
}
