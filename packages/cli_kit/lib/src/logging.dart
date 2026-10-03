import 'dart:async';
import 'dart:io';

import 'package:cli_util/cli_logging.dart';

abstract interface class LogOutput {
  bool get supportsAnsi;
  int get terminalColumns;
  void stdout(String message);
  void stderr(String message);
  void write(String message);
}

final class StreamLogOutput implements LogOutput {
  StreamLogOutput({
    required IOSink stdout,
    required IOSink stderr,
    required this.supportsAnsi,
    required int Function() terminalColumns,
  }) : _stdout = stdout,
       _stderr = stderr,
       _terminalColumns = terminalColumns;

  final IOSink _stdout;
  final IOSink _stderr;
  final int Function() _terminalColumns;
  @override
  final bool supportsAnsi;
  @override
  int get terminalColumns => _terminalColumns();
  @override
  void stdout(String message) => _stdout.writeln(message);
  @override
  void stderr(String message) => _stderr.writeln(message);
  @override
  void write(String message) => _stdout.write(message);
}

final class Log {
  Log({required this.output, bool verbose = false})
    : _verbose = verbose,
      ansi = Ansi(output.supportsAnsi);

  final LogOutput output;
  bool _verbose;
  final Ansi ansi;
  late final Glyph glyph = Glyph(ansi);

  static const _dim = '\u001B[2m';
  static const _reset = '\u001B[22m';

  String dim(String message) => ansi.useAnsi ? '$_dim$message$_reset' : message;

  bool get isVerbose => _verbose;

  void setVerbose() {
    stopStep();
    _verbose = true;
  }

  bool get _fancy => ansi.useAnsi && !_verbose;

  static const _detailColumn = 38;

  String _withDetail(String message, String detail) {
    final pad = message.length < _detailColumn
        ? ' ' * (_detailColumn - message.length)
        : ' ';
    return '$message$pad${dim(detail)}';
  }

  void logInfo(String message, [String? value]) => logStatus(
    '${glyph.info} '
    '${value == null ? message : '${message.padRight(13)}$value'}',
  );

  void logDone(String message, [String? detail]) => logStatus(
    '${glyph.ok} ${detail == null ? message : _withDetail(message, detail)}',
  );

  void logStatus(String message) {
    stopStep();
    output.stdout(message);
  }

  void logTrace(String message) {
    if (!_verbose) return;
    output.stdout(dim(message));
  }

  void logWarn(String message) {
    stopStep();
    output.stderr('${glyph.warn} $message');
  }

  void logError(String message) {
    stopStep();
    output.stderr('${glyph.bad} $message');
  }

  Future<T> logStep<T>(String label, Future<T> Function() body) async {
    final step = beginStep(label);
    try {
      final result = await body();
      step.done();
      return result;
    } on Object {
      step.fail();
      rethrow;
    }
  }

  Step beginStep(String label) {
    stopStep();
    return _active = Step._(this, label);
  }

  Step? get activeStep => _active;

  void stopStep() {
    final step = _active;
    _active = null;
    step?._erase();
  }

  Step? _active;
}

final class Glyph {
  Glyph(this.ansi);

  final Ansi ansi;
  String _mark(String color, String symbol) =>
      ansi.useAnsi ? '$color$symbol${ansi.none} ' : '';

  String get info => _mark(ansi.cyan, '›');

  String get ok => _mark(ansi.green, '✓');

  String get bad => _mark(ansi.red, '✗');

  String get warn => _mark(ansi.yellow, '!');

  String get download => _mark(ansi.cyan, '↓');
}

final class Step {
  Step._(this._log, this.label) : _watch = Stopwatch()..start() {
    if (_log._fancy) {
      _draw();
      return;
    }
    _log.output.stdout('${_log.glyph.info}$label…');
  }

  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  static const _tailLines = 3;
  static const _frameInterval = Duration(milliseconds: 80);

  final Log _log;
  final String label;
  final Stopwatch _watch;
  Timer? _timer;
  int _tick = 0;
  bool _closed = false;
  bool _suspended = false;

  final List<String> _tail = [];
  String _partial = '';
  int _drawn = 0;

  void log(String chunk) {
    if (_closed || _suspended || chunk.isEmpty) return;
    _partial += chunk.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final parts = _partial.split('\n');
    _partial = parts.removeLast();
    for (final line in parts) {
      if (_log._fancy) {
        _tail.add(line);
        if (_tail.length > _tailLines) _tail.removeAt(0);
      } else {
        _log.logTrace(line);
      }
    }
    if (_log._fancy) _draw();
  }

  void done([String? message]) =>
      _close(_log.glyph.ok, message ?? label, timed: true);

  void fail([String? message]) => _close(_log.glyph.bad, message ?? label);

  void _draw() {
    if (_closed || _suspended) return;
    _timer ??= Timer.periodic(_frameInterval, (_) => _draw());
    final tail = _visibleTail();
    final frame = _frames[_tick++ % _frames.length];
    _log.output.write(
      renderBlock(
        head: '${_log.ansi.cyan}$frame${_log.ansi.none} $label',
        tail: [for (final line in tail) _log.dim(_fit(line))],
        previousRows: _drawn,
      ),
    );
    _drawn = 1 + tail.length;
  }

  static String renderBlock({
    required String head,
    required List<String> tail,
    required int previousRows,
  }) {
    final buf = StringBuffer();
    if (previousRows > 0) buf.write('\x1B[${previousRows}A');
    buf.write('\r$head\x1B[K\n');
    for (final line in tail) {
      buf.write('\r    $line\x1B[K\n');
    }
    return buf.toString();
  }

  List<String> _visibleTail() {
    final partial = _partial.trimRight();
    if (partial.isEmpty) return _tail;
    final lines = [..._tail, partial];
    return lines.length > _tailLines
        ? lines.sublist(lines.length - _tailLines)
        : lines;
  }

  String _fit(String line) {
    final max = _log.output.terminalColumns - 6;
    if (max < 8 || line.length <= max) return line;
    return '${line.substring(0, max - 1)}…';
  }

  void _erase() {
    _suspended = true;
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    if (!_log._fancy) return;
    _log.output.write(_drawn > 0 ? '\r\x1B[${_drawn}A\x1B[J' : '\r\x1B[K');
    _drawn = 0;
  }

  void _close(String mark, String message, {bool timed = false}) {
    if (_closed) return;
    _closed = true;
    if (_log._active == this) _log._active = null;
    _erase();
    _watch.stop();
    final body = timed
        ? _log._withDetail(message, _fmtElapsed(_watch.elapsed))
        : message;
    _log.output.stdout('$mark$body');
  }

  static String _fmtElapsed(Duration d) {
    if (d.inMinutes >= 1) {
      return '${d.inMinutes}m${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
    }
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
}
