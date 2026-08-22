import 'dart:async';
import 'dart:io';

import 'package:cli_util/cli_logging.dart';

/// Global logging and status-line facilities for the CLI.
abstract final class Log {
  static Logger _logger = Logger.standard();

  /// Bright black (SGR 90), the readable "dim" on both dark and light
  /// terminals.
  ///
  /// cli_util's own `ansi.gray` is `1;30` — *bold black* — which renders as
  /// pure black on a dark background: `--verbose` trace output and every
  /// subtle detail were invisible. SGR 90 is the modern bright-black slot
  /// every terminal that supports ANSI colors renders as a real grey.
  static const _dim = '\u001B[90m';
  static const _reset = '\u001B[0m';

  /// [message] in a readable grey, or unchanged when ANSI is off (piped
  /// output, dumb terminal).
  static String dim(String message) =>
      ansi.useAnsi ? '$_dim$message$_reset' : message;

  /// Whether `--verbose` was passed.
  static bool get isVerbose => _logger.isVerbose;

  /// Switches the global logger to verbose mode (trace output, no spinners).
  static void setVerbose() {
    stopStep();
    _logger = Logger.verbose();
  }

  /// ANSI helpers; colors are stripped automatically on a non-TTY.
  static Ansi get ansi => _logger.ansi;

  static bool get _fancy => _logger.ansi.useAnsi && !_logger.isVerbose;

  static const _detailColumn = 38;

  static String _withDetail(String message, String detail) {
    final pad = message.length < _detailColumn
        ? ' ' * (_detailColumn - message.length)
        : ' ';
    return '$message$pad${dim(detail)}';
  }

  /// A user-facing fact: `› Device   iPhone 15 Pro`.
  static void logInfo(String message, [String? value]) => logStatus(
    '${Glyph.info} '
    '${value == null ? message : '${message.padRight(13)}$value'}',
  );

  /// A one-off completed action that had no [Step].
  static void logDone(String message, [String? detail]) => logStatus(
    '${Glyph.ok} ${detail == null ? message : _withDetail(message, detail)}',
  );

  /// Prints [message] verbatim, interrupting any running spinner.
  static void logStatus(String message) {
    stopStep();
    _logger.stdout(message);
  }

  /// A detail line, shown only with `--verbose`.
  ///
  /// Routed through [stdout] rather than `trace`: cli_util colors trace with
  /// its invisible bold-black, so the whole verbose stream was unreadable.
  static void logTrace(String message) {
    if (!_logger.isVerbose) return;
    _logger.stdout(dim(message));
  }

  /// A warning on stderr.
  static void logWarn(String message) {
    stopStep();
    _logger.stderr('${Glyph.warn} $message');
  }

  /// An error on stderr.
  static void logError(String message) {
    stopStep();
    _logger.stderr('${Glyph.bad} $message');
  }

  /// Runs [body] under a spinner labelled [label], reporting success or
  /// failure when it settles.
  static Future<T> logStep<T>(String label, Future<T> Function() body) async {
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

  /// Starts a spinner; the caller must call [Step.done] or [Step.fail].
  static Step beginStep(String label) {
    stopStep();
    return _active = Step._(label);
  }

  /// The phase currently on screen, or null when nothing is running.
  ///
  /// Lets a helper deep in a call stack stream its subprocess output into the
  /// phase its caller already opened, instead of every layer in between having
  /// to pass a [Step] down purely to keep the tail alive.
  static Step? get activeStep => _active;

  /// Erases any running spinner so direct stdout writers get a clean line.
  static void stopStep() {
    final step = _active;
    _active = null;
    step?._erase();
  }

  static Step? _active;
}

/// Line markers that keep all CLI output reading as one coherent list.
abstract final class Glyph {
  static String _mark(String color, String symbol) =>
      Log.ansi.useAnsi ? '$color$symbol${Log.ansi.none} ' : '';

  /// A fact, or a phase that has just started.
  static String get info => _mark(Log.ansi.cyan, '›');

  /// A phase that finished.
  static String get ok => _mark(Log.ansi.green, '✓');

  /// A phase that failed.
  static String get bad => _mark(Log.ansi.red, '✗');

  /// Something worth knowing, but not fatal.
  static String get warn => _mark(Log.ansi.yellow, '!');

  /// A transfer in flight.
  static String get download => _mark(Log.ansi.cyan, '↓');
}

/// A single in-progress phase rendered as a spinner with a collapsing tail.
final class Step {
  Step._(this.label) : _watch = Stopwatch()..start() {
    if (Log._fancy) {
      _draw();
      return;
    }
    Log._logger.stdout('${Glyph.info}$label…');
  }

  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  static const _tailLines = 3;
  static const _frameInterval = Duration(milliseconds: 80);

  final String label;
  final Stopwatch _watch;
  Timer? _timer;
  int _tick = 0;
  bool _closed = false;

  final List<String> _tail = [];
  String _partial = '';
  int _drawn = 0;

  /// Feeds subprocess output into the grey tail under the spinner; off a
  /// fancy TTY the lines go to trace instead.
  void log(String chunk) {
    if (_closed || chunk.isEmpty) return;
    _partial += chunk.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final parts = _partial.split('\n');
    _partial = parts.removeLast();
    for (final line in parts) {
      if (Log._fancy) {
        _tail.add(line);
        if (_tail.length > _tailLines) _tail.removeAt(0);
      } else {
        Log.logTrace(line);
      }
    }
    if (Log._fancy) _draw();
  }

  /// Replaces the spinner with a success line, discarding the tail.
  void done([String? message]) =>
      _close(Glyph.ok, message ?? label, timed: true);

  /// Replaces the spinner with a failure line, discarding the tail.
  void fail([String? message]) => _close(Glyph.bad, message ?? label);

  void _draw() {
    _timer ??= Timer.periodic(_frameInterval, (_) => _draw());
    final tail = _visibleTail();
    final frame = _frames[_tick++ % _frames.length];
    stdout.write(
      renderBlock(
        head: '${Log.ansi.cyan}$frame${Log.ansi.none} $label',
        tail: [for (final line in tail) Log.dim(_fit(line))],
        previousRows: _drawn,
      ),
    );
    _drawn = 1 + tail.length;
  }

  /// The escape sequence that repaints a [head] line plus indented [tail]
  /// lines over the [previousRows] rows drawn last time.
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

  static String _fit(String line) {
    final max = (stdout.hasTerminal ? stdout.terminalColumns : 80) - 6;
    if (max < 8 || line.length <= max) return line;
    return '${line.substring(0, max - 1)}…';
  }

  void _erase() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    if (!Log._fancy) return;
    stdout.write(_drawn > 0 ? '\r\x1B[${_drawn}A\x1B[J' : '\r\x1B[K');
    _drawn = 0;
  }

  void _close(String mark, String message, {bool timed = false}) {
    if (_closed) return;
    _closed = true;
    if (Log._active == this) Log._active = null;
    _erase();
    final body = timed
        ? Log._withDetail(message, _fmtElapsed(_watch.elapsed))
        : message;
    Log._logger.stdout('$mark$body');
  }

  static String _fmtElapsed(Duration d) {
    if (d.inMinutes >= 1) {
      return '${d.inMinutes}m${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
    }
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
}
