import 'dart:collection';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
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

  test('runner omits configured top-level commands', () async {
    final runner = XcrossCli.buildRunner(
      excludedCommands: const ['setup', 'config'],
    );

    expect(runner.commands, isNot(contains('setup')));
    expect(runner.commands, isNot(contains('config')));
    expect(runner.commands, contains('doctor'));
    await expectLater(
      runner.run(['setup']),
      throwsA(
        isA<UsageException>().having(
          (error) => error.message,
          'message',
          contains('Could not find a command named "setup"'),
        ),
      ),
    );
  });

  test(
    'controller switches tabs in both directions and clamps selection',
    () async {
      final controller = ConfigTuiController(XcrossConfig());
      await handle(controller, TuiKey.backTab);
      expect(controller.tab, ConfigTab.commands);
      await handle(controller, TuiKey.tab);
      await handle(controller, TuiKey.right);
      expect(controller.tab, ConfigTab.toolchains);
      await handle(controller, TuiKey.left);
      expect(controller.tab, ConfigTab.roots);
      await handle(controller, TuiKey.up);
      expect(controller.selection, controller.itemCount - 1);
      await handle(controller, TuiKey.down);
      expect(controller.selection, 0);
    },
  );

  test('controller edits fixed rows and adds and edits map entries', () async {
    final controller = ConfigTuiController(XcrossConfig());
    await handle(controller, TuiKey.enter, answers: ['/opt/darwin']);
    expect(controller.config.roots.darwinSdk, '/opt/darwin');

    controller.tab = ConfigTab.toolchains;
    controller.selection = 1;
    await handle(controller, TuiKey.enter, answers: ['/llvm/a, /llvm/b']);
    expect(controller.config.toolchains.llvm, ['/llvm/a', '/llvm/b']);

    controller.tab = ConfigTab.tools;
    controller.selection = 0;
    await handle(
      controller,
      TuiKey.enter,
      answers: ['Clang.EXE', '/bin/clang'],
    );
    expect(controller.config.tools, {'clang': '/bin/clang'});
    controller.selection = 0;
    await handle(controller, TuiKey.enter, answers: ['/usr/bin/clang']);
    expect(controller.config.tools['clang'], '/usr/bin/clang');

    controller.tab = ConfigTab.environment;
    controller.selection = 0;
    await handle(controller, TuiKey.enter, answers: ['PATH', '/one, /two']);
    expect(controller.config.environment['PATH'], ['/one', '/two']);

    controller.tab = ConfigTab.commands;
    controller.selection = 0;
    await handle(controller, TuiKey.enter, answers: ['setup']);
    expect(controller.config.excludedCommands, {'setup'});
  });

  test('delete requires confirmation and ignores Add row', () async {
    final controller = ConfigTuiController(
      XcrossConfig(tools: const {'clang': '/bin/clang'}),
    )..tab = ConfigTab.tools;
    await handle(controller, TuiKey.delete, confirmations: [false]);
    expect(controller.config.tools, contains('clang'));
    await handle(controller, TuiKey.delete, confirmations: [true]);
    expect(controller.config.tools, isEmpty);
    expect(controller.dirty, isTrue);
    await handle(controller, TuiKey.delete, confirmations: [true]);
    expect(controller.config.tools, isEmpty);
  });

  test('save resets dirty state and discard restores saved state', () async {
    final controller = ConfigTuiController(XcrossConfig());
    XcrossConfig? saved;
    await handle(controller, TuiKey.enter, answers: ['/first']);
    expect(controller.dirty, isTrue);
    await handle(
      controller,
      TuiKey.save,
      save: (config) async {
        saved = config;
        return '/config.yaml';
      },
    );
    expect(controller.dirty, isFalse);
    expect(controller.status, 'Saved /config.yaml');
    expect(saved!.roots.darwinSdk, '/first');

    await handle(controller, TuiKey.enter, answers: ['/second']);
    await handle(controller, TuiKey.discard, confirmations: [false]);
    expect(controller.config.roots.darwinSdk, '/second');
    await handle(controller, TuiKey.discard, confirmations: [true]);
    expect(controller.config.roots.darwinSdk, '/first');
    expect(controller.dirty, isFalse);
  });

  test('quit confirms only when dirty and validate reports status', () async {
    final clean = ConfigTuiController(XcrossConfig());
    expect(await handle(clean, TuiKey.quit), isTrue);
    await handle(clean, TuiKey.validate);
    expect(clean.status, 'Configuration is valid.');

    await handle(clean, TuiKey.enter, answers: ['/changed']);
    expect(await handle(clean, TuiKey.quit, confirmations: [false]), isFalse);
    expect(await handle(clean, TuiKey.quit, confirmations: [true]), isTrue);
  });

  test('render includes ANSI redraw, tabs, rows, actions, and selection', () {
    final controller =
        ConfigTuiController(
            XcrossConfig(
              tools: const {'clang': '/bin/clang'},
              environment: const {
                'PATH': ['/one', '/two'],
              },
            ),
          )
          ..tab = ConfigTab.tools
          ..selection = 1;
    final output = controller.render();
    final plain = output.replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '');
    expect(output, startsWith(AnsiTuiRenderer.clearScreen));
    expect(output, contains(AnsiTuiStyle.title));
    expect(output, contains(AnsiTuiStyle.selectedTab));
    expect(output, contains(AnsiTuiStyle.selectedRow));
    expect(output, contains(AnsiTuiStyle.actionBackgrounds.first));
    expect(plain, contains('xcross config'));
    expect(plain, contains('Tools'));
    expect(plain, contains('clang: /bin/clang'));
    expect(plain, contains('› + Add'));
    expect(plain, contains('Save'));
    expect(plain, contains('Validate'));
    expect(plain, contains('Discard'));
    expect(plain, contains('Quit'));
    expect(plain, contains('Tab/←/→ tabs'));
  });

  test('plain rendering emits one frame and incremental updates', () {
    final controller = ConfigTuiController(XcrossConfig());
    final frame = controller.render(ansi: false);
    final update = controller.renderPlainUpdate();

    expect(frame, contains('=== xcross config ==='));
    expect(update, '[Roots] > darwinSdk: <unset>');
    expect(update, isNot(contains('\x1b[')));
  });

  test(
    'interactive command restores terminal modes around prompts and exit',
    () async {
      final terminal = FakeTerminal(
        bytes: [13, 113],
        lines: ['/opt/flutter', 'y'],
      );
      final runner = CommandRunner<void>('xcross', 'test')
        ..addCommand(ConfigCommand(store: store, terminal: terminal));
      await runner.run(['config']);
      expect(terminal.modeChanges, [
        'raw',
        'cooked',
        'raw',
        'cooked',
        'raw',
        'cooked',
      ]);
      expect(terminal.output.join(), contains('\x1b[2J\x1b[H'));
      expect(store.selectedFile(), isNull);
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

  test('interactive command requires a TTY', () async {
    final runner = CommandRunner<void>('xcross', 'test')
      ..addCommand(
        ConfigCommand(store: store, terminal: FakeTerminal(interactive: false)),
      );
    await expectLater(
      runner.run(['config']),
      throwsA(
        predicate((error) => error.toString().contains('requires a TTY')),
      ),
    );
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

Future<bool> handle(
  ConfigTuiController controller,
  TuiKey key, {
  List<String> answers = const [],
  List<bool> confirmations = const [],
  Future<String> Function(XcrossConfig config)? save,
}) {
  final answerQueue = Queue<String>.of(answers);
  final confirmationQueue = Queue<bool>.of(confirmations);
  return controller.handle(
    key,
    prompt: (_) => answerQueue.isEmpty ? null : answerQueue.removeFirst(),
    confirm: (_) =>
        confirmationQueue.isNotEmpty && confirmationQueue.removeFirst(),
    save: save ?? (_) async => '/config.yaml',
    validate: (_) {},
  );
}

final class FakeTerminal implements TuiTerminal {
  FakeTerminal({
    this.interactive = true,
    List<int> bytes = const [],
    List<String> lines = const [],
  }) : _bytes = Queue<int>.of(bytes),
       _lines = Queue<String>.of(lines);

  final bool interactive;
  final Queue<int> _bytes;
  final Queue<String> _lines;
  final output = <String>[];
  final modeChanges = <String>[];

  @override
  bool get isInteractive => interactive;

  @override
  void enterRaw() => modeChanges.add('raw');

  @override
  void leaveRaw() => modeChanges.add('cooked');

  @override
  int readByte() => _bytes.removeFirst();

  @override
  String? readLine() => _lines.isEmpty ? null : _lines.removeFirst();

  @override
  void write(String value) => output.add(value);
}
