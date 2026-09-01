import 'dart:io';

enum TuiKey {
  tab,
  backTab,
  left,
  right,
  up,
  down,
  enter,
  delete,
  save,
  validate,
  discard,
  quit,
  other,
}

abstract interface class TuiTerminal {
  bool get isInteractive;
  void enterRaw();
  void leaveRaw();
  int readByte();
  String? readLine();
  void write(String value);
}

final class IoTuiTerminal implements TuiTerminal {
  late bool _echoMode;
  late bool _lineMode;
  bool _raw = false;

  @override
  bool get isInteractive => stdin.hasTerminal;

  @override
  void enterRaw() {
    if (_raw) return;
    _echoMode = stdin.echoMode;
    _lineMode = stdin.lineMode;
    stdin
      ..echoMode = false
      ..lineMode = false;
    _raw = true;
  }

  @override
  void leaveRaw() {
    if (!_raw) return;
    stdin
      ..echoMode = _echoMode
      ..lineMode = _lineMode;
    _raw = false;
  }

  @override
  int readByte() => stdin.readByteSync();

  @override
  String? readLine() => stdin.readLineSync();

  @override
  void write(String value) => stdout.write(value);
}

abstract final class AnsiTuiStyle {
  static const reset = '\x1b[0m';
  static const title = '\x1b[1;97;44m';
  static const selectedTab = '\x1b[1;30;46m';
  static const tab = '\x1b[36m';
  static const selectedRow = '\x1b[30;47m';
  static const row = '\x1b[37m';
  static const help = '\x1b[2;37m';
  static const status = '\x1b[1;35m';
  static const prompt = '\x1b[1;97;44m';
  static const actionSelected = '\x1b[1;30;47m';
  static const actionBackgrounds = [
    '\x1b[1;30;42m',
    '\x1b[1;97;44m',
    '\x1b[1;30;43m',
    '\x1b[1;97;41m',
  ];

  static String paint(String style, String value) => '$style$value$reset';
}

abstract final class AnsiTuiRenderer {
  static const clearScreen = '\x1b[2J\x1b[H';
  static const reset = AnsiTuiStyle.reset;

  static String frame({
    required String title,
    required List<String> tabs,
    required int selectedTab,
    required List<String> rows,
    required int selection,
    required List<String> actions,
    String help = '',
    String status = '',
    bool ansi = true,
    bool color = true,
  }) {
    if (!ansi) {
      return _plainFrame(
        title: title,
        tabs: tabs,
        selectedTab: selectedTab,
        rows: rows,
        selection: selection,
        actions: actions,
        help: help,
        status: status,
      );
    }
    String paint(String style, String value) =>
        color ? AnsiTuiStyle.paint(style, value) : value;
    final buffer = StringBuffer(
      '$clearScreen${paint(AnsiTuiStyle.title, ' $title ')}\n\n',
    );
    for (var index = 0; index < tabs.length; index++) {
      final selected = index == selectedTab;
      final label = selected ? ' ${tabs[index]} ' : ' ${tabs[index]} ';
      buffer.write(
        '${paint(selected ? AnsiTuiStyle.selectedTab : AnsiTuiStyle.tab, label)} ',
      );
    }
    buffer.writeln('\n');
    for (var index = 0; index < rows.length; index++) {
      final selected = selection == index;
      final row = '${selected ? ' ›' : '  '} ${rows[index]} ';
      buffer.writeln(
        paint(selected ? AnsiTuiStyle.selectedRow : AnsiTuiStyle.row, row),
      );
    }
    buffer.writeln();
    for (var index = 0; index < actions.length; index++) {
      final selected = selection == rows.length + index;
      final style = selected
          ? AnsiTuiStyle.actionSelected
          : AnsiTuiStyle.actionBackgrounds[index %
                AnsiTuiStyle.actionBackgrounds.length];
      buffer.write(
        '${selected ? '›' : ' '} ${paint(style, ' ${actions[index]} ')}  ',
      );
    }
    if (help.isNotEmpty) {
      buffer.writeln('\n\n${paint(AnsiTuiStyle.help, help)}');
    }
    if (status.isNotEmpty) {
      buffer.writeln('\n${paint(AnsiTuiStyle.status, status)}');
    }
    return buffer.toString();
  }

  static String plainUpdate({
    required String tab,
    required String item,
    String status = '',
  }) {
    final suffix = status.isEmpty ? '' : ' — $status';
    return '[$tab] > $item$suffix';
  }

  static String _plainFrame({
    required String title,
    required List<String> tabs,
    required int selectedTab,
    required List<String> rows,
    required int selection,
    required List<String> actions,
    required String help,
    required String status,
  }) {
    final buffer = StringBuffer('=== $title ===\n\n');
    for (var index = 0; index < tabs.length; index++) {
      buffer.write(
        index == selectedTab ? '[${tabs[index]}] ' : '${tabs[index]} ',
      );
    }
    buffer.writeln('\n');
    for (var index = 0; index < rows.length; index++) {
      buffer.writeln('${selection == index ? '>' : ' '} ${rows[index]}');
    }
    buffer.writeln();
    for (var index = 0; index < actions.length; index++) {
      final selected = selection == rows.length + index;
      buffer.write('${selected ? '>' : ' '}[${actions[index]}] ');
    }
    if (help.isNotEmpty) buffer.writeln('\n\n$help');
    if (status.isNotEmpty) buffer.writeln('\n$status');
    return buffer.toString();
  }
}

final class AnsiTui {
  AnsiTui({
    TuiTerminal? terminal,
    Map<String, String>? environment,
    bool? useAnsi,
    bool? useColor,
  }) : terminal = terminal ?? IoTuiTerminal(),
       useAnsi = useAnsi ?? supportsAnsi(environment ?? Platform.environment),
       useColor =
           useColor ?? supportsColor(environment ?? Platform.environment);

  final TuiTerminal terminal;
  final bool useAnsi;
  final bool useColor;
  int _plainLineWidth = 0;

  static bool supportsAnsi(Map<String, String> environment) =>
      !environment.containsKey('NO_ANSI') &&
      environment['TERM']?.toLowerCase() != 'dumb';

  static bool supportsColor(Map<String, String> environment) =>
      supportsAnsi(environment) && !environment.containsKey('NO_COLOR');

  Future<void> run({
    required String Function() render,
    required Future<bool> Function(TuiKey key) handle,
    String Function()? renderPlainUpdate,
  }) async {
    terminal.enterRaw();
    try {
      terminal.write(render());
      var quit = false;
      while (!quit) {
        quit = await handle(readKey());
        if (quit) continue;
        if (useAnsi) {
          terminal.write(render());
        } else if (renderPlainUpdate case final update?) {
          _writePlainUpdate(update());
        }
      }
    } finally {
      terminal.leaveRaw();
      if (useAnsi) {
        terminal.write('${AnsiTuiRenderer.reset}\n');
      } else if (_plainLineWidth > 0) {
        terminal.write('\r${' ' * _plainLineWidth}\r');
        _plainLineWidth = 0;
      }
    }
  }

  String prompt(String label) {
    terminal.leaveRaw();
    if (!useAnsi && _plainLineWidth > 0) {
      terminal.write('\r${' ' * _plainLineWidth}\r');
      _plainLineWidth = 0;
    }
    terminal.write(
      useAnsi
          ? '${AnsiTuiRenderer.clearScreen}'
                '${useColor ? AnsiTuiStyle.paint(AnsiTuiStyle.prompt, ' $label ') : '$label: '}'
          : '\n$label: ',
    );
    try {
      final value = terminal.readLine();
      if (value == null) throw StateError('Terminal input closed.');
      return value.trim();
    } finally {
      terminal.enterRaw();
    }
  }

  bool confirm(String label) {
    final answer = prompt(label).toLowerCase();
    return answer == 'y' || answer == 'yes';
  }

  void _writePlainUpdate(String value) {
    final padding = _plainLineWidth > value.length
        ? ' ' * (_plainLineWidth - value.length)
        : '';
    terminal.write('\r$value$padding');
    _plainLineWidth = value.length;
  }

  TuiKey readKey() {
    final byte = terminal.readByte();
    if (byte == 9) return TuiKey.tab;
    if (byte == 10 || byte == 13) return TuiKey.enter;
    if (byte == 127 || byte == 8) return TuiKey.delete;
    if (byte == 27) {
      if (terminal.readByte() != 91) return TuiKey.other;
      return switch (terminal.readByte()) {
        65 => TuiKey.up,
        66 => TuiKey.down,
        67 => TuiKey.right,
        68 => TuiKey.left,
        90 => TuiKey.backTab,
        51 => terminal.readByte() == 126 ? TuiKey.delete : TuiKey.other,
        _ => TuiKey.other,
      };
    }
    return switch (byte) {
      113 => TuiKey.quit,
      115 => TuiKey.save,
      118 => TuiKey.validate,
      114 => TuiKey.discard,
      _ => TuiKey.other,
    };
  }
}
