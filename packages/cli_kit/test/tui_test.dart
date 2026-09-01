import 'dart:collection';

import 'package:cli_kit/cli_kit.dart';
import 'package:test/test.dart';

void main() {
  test('renders an ANSI frame with tabs, rows, actions, and status', () {
    final output = AnsiTuiRenderer.frame(
      title: 'Settings *',
      tabs: const ['First', 'Second'],
      selectedTab: 1,
      rows: const ['one', 'two'],
      selection: 2,
      actions: const ['Save', 'Quit'],
      help: 'Help',
      status: 'Changed',
    );

    final plain = stripAnsi(output);
    expect(output, startsWith(AnsiTuiRenderer.clearScreen));
    expect(output, contains(AnsiTuiStyle.title));
    expect(output, contains(AnsiTuiStyle.selectedTab));
    expect(output, contains(AnsiTuiStyle.row));
    expect(output, contains(AnsiTuiStyle.actionSelected));
    expect(output, contains(AnsiTuiStyle.status));
    expect(plain, contains(' Settings * '));
    expect(plain, contains(' First   Second '));
    expect(plain, contains('   one \n   two '));
    expect(plain, contains('›  Save '));
    expect(plain, contains(' Quit '));
    expect(plain, contains('Help\n\nChanged'));
  });

  test('decodes navigation, action, and delete keys', () {
    final terminal = FakeTerminal(
      bytes: [
        9,
        27,
        91,
        90,
        27,
        91,
        65,
        27,
        91,
        66,
        27,
        91,
        67,
        27,
        91,
        68,
        13,
        127,
        27,
        91,
        51,
        126,
        115,
        118,
        114,
        113,
      ],
    );
    final tui = AnsiTui(terminal: terminal);

    expect(List.generate(13, (_) => tui.readKey()), [
      TuiKey.tab,
      TuiKey.backTab,
      TuiKey.up,
      TuiKey.down,
      TuiKey.right,
      TuiKey.left,
      TuiKey.enter,
      TuiKey.delete,
      TuiKey.delete,
      TuiKey.save,
      TuiKey.validate,
      TuiKey.discard,
      TuiKey.quit,
    ]);
  });

  test('run restores cooked mode when handling fails', () async {
    final terminal = FakeTerminal(bytes: [13]);
    final tui = AnsiTui(terminal: terminal);

    await expectLater(
      tui.run(render: () => 'frame', handle: (_) => throw StateError('failed')),
      throwsStateError,
    );
    expect(terminal.modeChanges, ['raw', 'cooked']);
    expect(terminal.output, ['frame', '${AnsiTuiRenderer.reset}\n']);
  });

  test('prompts in cooked mode and restores raw mode', () {
    final terminal = FakeTerminal(lines: [' value ', 'yes']);
    final tui = AnsiTui(terminal: terminal, useColor: true);

    expect(tui.prompt('Value'), 'value');
    expect(tui.confirm('Continue? [y/N]'), isTrue);
    expect(terminal.modeChanges, ['cooked', 'raw', 'cooked', 'raw']);
    expect(terminal.output.first, startsWith(AnsiTuiRenderer.clearScreen));
    expect(terminal.output.first, contains(AnsiTuiStyle.prompt));
    expect(stripAnsi(terminal.output.first), contains(' Value '));
  });

  test('detects independent control and color capabilities', () {
    expect(AnsiTui.supportsAnsi(const {}), isTrue);
    expect(AnsiTui.supportsColor(const {}), isTrue);
    expect(AnsiTui.supportsAnsi(const {'NO_COLOR': ''}), isTrue);
    expect(AnsiTui.supportsColor(const {'NO_COLOR': ''}), isFalse);
    expect(AnsiTui.supportsAnsi(const {'NO_ANSI': '1'}), isFalse);
    expect(AnsiTui.supportsColor(const {'NO_ANSI': '1'}), isFalse);
    expect(AnsiTui.supportsAnsi(const {'TERM': 'dumb'}), isFalse);
    expect(AnsiTui.supportsColor(const {'TERM': 'dumb'}), isFalse);
  });

  test('renders full-screen controls without colors', () {
    final output = AnsiTuiRenderer.frame(
      title: 'Settings',
      tabs: const ['First'],
      selectedTab: 0,
      rows: const ['one', 'two'],
      selection: 1,
      actions: const ['Quit'],
      color: false,
    );

    expect(output, startsWith(AnsiTuiRenderer.clearScreen));
    expect(output, contains(' › two'));
    expect(output, isNot(contains(AnsiTuiStyle.title)));
    expect(output, isNot(contains(AnsiTuiStyle.reset)));
  });

  test('renders plain text and reads arrows in raw mode', () async {
    final frame = AnsiTuiRenderer.frame(
      title: 'Settings',
      tabs: const ['First', 'Second'],
      selectedTab: 0,
      rows: const ['one'],
      selection: 0,
      actions: const ['Quit'],
      ansi: false,
    );
    expect(frame, startsWith('=== Settings ==='));
    expect(frame, contains('[First] Second'));
    expect(frame, contains('> one'));
    expect(frame, isNot(contains('\x1b[')));

    final terminal = FakeTerminal(bytes: [27, 91, 65, 113]);
    final keys = <TuiKey>[];
    final tui = AnsiTui(terminal: terminal, useAnsi: false);
    await tui.run(
      render: () => frame,
      renderPlainUpdate: () =>
          AnsiTuiRenderer.plainUpdate(tab: 'First', item: 'one'),
      handle: (key) async {
        keys.add(key);
        return key == TuiKey.quit;
      },
    );

    expect(keys, [TuiKey.up, TuiKey.quit]);
    expect(terminal.modeChanges, ['raw', 'cooked']);
    expect(terminal.output.join(), isNot(contains('\x1b[')));
    expect(terminal.output, [frame, '\r[First] > one', '\r${' ' * 13}\r']);
    expect(terminal.output.join().split('=== Settings ===').length - 1, 1);
  });

  test('plain prompts contain no ANSI sequences', () {
    final terminal = FakeTerminal(lines: ['value']);
    final tui = AnsiTui(terminal: terminal, useAnsi: false);

    expect(tui.prompt('Value'), 'value');
    expect(terminal.modeChanges, ['cooked', 'raw']);
    expect(terminal.output, ['\nValue: ']);
  });

  test('plain prompt clears the active status line', () async {
    final terminal = FakeTerminal(
      bytes: [27, 91, 65, 13, 113],
      lines: ['value'],
    );
    final tui = AnsiTui(terminal: terminal, useAnsi: false);
    var handled = 0;

    await tui.run(
      render: () => 'frame\n',
      renderPlainUpdate: () => '[First] > one',
      handle: (key) async {
        handled++;
        if (handled == 2) expect(tui.prompt('Value'), 'value');
        return key == TuiKey.quit;
      },
    );

    final output = terminal.output.join();
    expect(output, contains('\nValue: '));
    expect(output, isNot(contains('\x1b[')));
    expect(terminal.modeChanges, ['raw', 'cooked', 'raw', 'cooked']);
  });
}

String stripAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '');

final class FakeTerminal implements TuiTerminal {
  FakeTerminal({List<int> bytes = const [], List<String> lines = const []})
    : _bytes = Queue<int>.of(bytes),
      _lines = Queue<String>.of(lines);

  final Queue<int> _bytes;
  final Queue<String> _lines;
  final output = <String>[];
  final modeChanges = <String>[];

  @override
  bool get isInteractive => true;

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
