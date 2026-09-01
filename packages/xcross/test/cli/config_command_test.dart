import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/config_command.dart';
import 'package:xcross/src/cli/runner.dart';
import 'package:xcross/src/config/config.dart';

void main() {
  late Directory temporary;
  late XcrossConfigStore store;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('xcross-config-command-');
    store = XcrossConfigStore(
      directory: temporary.path,
      environment: const {},
      windows: false,
    );
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test('runner registers top-level config command', () {
    expect(XcrossCli.buildRunner().commands['config'], isA<ConfigCommand>());
  });

  test(
    'interactive numbered menu saves optional roots and PATH list',
    () async {
      final input = <String>[
        '1',
        '2',
        '/opt/flutter',
        '3',
        'llvm',
        '/llvm/one, /llvm/two',
        '4',
        'PATH',
        '/one, /two',
        '8',
        '10',
      ].iterator;
      final output = <String>[];
      final command = ConfigCommand(
        store: store,
        readLine: () => input.moveNext() ? input.current : null,
        writeLine: output.add,
        isInteractive: () => true,
      );

      await (CommandRunner<void>(
        'xcross',
        'test',
      )..addCommand(command)).run(['config']);

      final config = await store.load();
      expect(config!.roots.flutterSdk, '/opt/flutter');
      expect(config.roots.darwinSdk, isNull);
      expect(config.toolchains.llvm, ['/llvm/one', '/llvm/two']);
      expect(config.environment['PATH'], ['/one', '/two']);
      expect(output, contains(startsWith('Saved ')));
    },
  );

  test('show emits serializer output and validate reports success', () async {
    final executable = File(p.join(temporary.path, 'tool'))
      ..writeAsStringSync('#!/bin/sh\n');
    Process.runSync('chmod', ['755', executable.path]);
    final config = XcrossConfig(
      roots: const XcrossConfigRoots(darwinSdk: '/missing/sdk'),
      tools: {'tool': executable.path},
    );
    await store.save(config);
    final output = <String>[];
    final runner = CommandRunner<void>('xcross', 'test')
      ..addCommand(ConfigCommand(store: store, writeLine: output.add));

    await runner.run(['config', 'show']);
    expect(output, [
      'Selected: ${store.selectedFile()!.path}',
      config.toYaml(),
    ]);
    output.clear();
    await runner.run(['config', 'validate']);
    expect(output, ['Configuration is valid.']);
  });

  test('interactive command requires an injected TTY', () async {
    final runner = CommandRunner<void>('xcross', 'test')
      ..addCommand(
        ConfigCommand(
          store: store,
          isInteractive: () => false,
          writeLine: (_) {},
        ),
      );
    await expectLater(
      runner.run(['config']),
      throwsA(
        predicate((error) => error.toString().contains('requires a TTY')),
      ),
    );
  });

  test('dirty exit warns and can retain editing session', () async {
    final input = ['1', '2', '/opt/flutter', '10', 'n', '10', 'y'].iterator;
    final output = <String>[];
    final runner = CommandRunner<void>('xcross', 'test')
      ..addCommand(
        ConfigCommand(
          store: store,
          readLine: () => input.moveNext() ? input.current : null,
          writeLine: output.add,
          isInteractive: () => true,
        ),
      );
    await runner.run(['config']);
    expect(
      output.where((line) => line.startsWith('Unsaved changes.')).length,
      2,
    );
    expect(store.selectedFile(), isNull);
  });

  test('validate rejects a missing configured tool', () async {
    await store.save(
      XcrossConfig(tools: {'missing': p.join(temporary.path, 'missing')}),
    );
    final runner = CommandRunner<void>('xcross', 'test')
      ..addCommand(ConfigCommand(store: store, writeLine: (_) {}));

    await expectLater(
      runner.run(['config', 'validate']),
      throwsA(isA<XcrossConfigException>()),
    );
  });
}
