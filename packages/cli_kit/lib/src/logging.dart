import 'dart:async';
import 'dart:io';

import 'package:cli_util/cli_logging.dart';

/// Global logging/status-line facilities for the CLI.
abstract final class Log {
  static Logger _logger = Logger.standard();

  /// Whether `--verbose` was passed. Trace output is only rendered when true.
  static bool get isVerbose => _logger.isVerbose;

  /// Switch global logger to verbose mode (shows trace output, no spinners).
  static void setVerbose() {
    stopStep();
    _logger = Logger.verbose();
  }

  /// ANSI helpers (colors are stripped automatically on a non-TTY).
  static Ansi get ansi => _logger.ansi;

  static bool get _fancy => _logger.ansi.useAnsi && !_logger.isVerbose;

  /// Column the dim right-hand detail (elapsed time, size) is padded out to.
  static const _detailColumn = 38;

  /// `message` padded so [detail] lines up with every other line's detail.
  static String _withDetail(String message, String detail) {
    final pad = message.length < _detailColumn
        ? ' ' * (_detailColumn - message.length)
        : ' ';
    return '$message$pad${ansi.subtle(detail)}';
  }

  /// A user-facing fact: `› Device   iPhone 15 Pro`. Interrupts any spinner.
  ///
  /// With a [value], [message] becomes a padded label so consecutive facts
  /// line up in a column.
  static void logInfo(String message, [String? value]) => logStatus(
    '${Glyph.info} '
    '${value == null ? message : '${message.padRight(13)}$value'}',
  );

  /// A one-off completed action that had no [Step]: `✓ Flutter iOS engine 279 MB`.
  static void logDone(String message, [String? detail]) => logStatus(
    '${Glyph.ok} ${detail == null ? message : _withDetail(message, detail)}',
  );

  /// Print [message] verbatim (already carries its own marker). Interrupts any
  /// running spinner so the two never fight over the same line.
  static void logStatus(String message) {
    stopStep();
    _logger.stdout(message);
  }

  /// A detail line — only shown with `--verbose`. Use this for command lines,
  /// timings, and per-tool chatter that would otherwise flood the console.
  static void logTrace(String message) => _logger.trace(message);

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

  /// Run [body] under a spinner labelled [label]; prints `✓ label 1.2s` when
  /// it returns, `✗ label` when it throws.
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

  /// Start a spinner for work that cannot be wrapped in a closure. The caller
  /// must call [Step.done] or [Step.fail].
  static Step beginStep(String label) {
    stopStep();
    return _active = Step._(label);
  }

  /// Erase any running spinner — for code that writes to stdout directly
  /// (e.g. the download progress bar).
  static void stopStep() {
    final step = _active;
    _active = null;
    step?._erase();
  }

  static Step? _active;
}

/// Every line xcross prints starts with one of these markers, so output reads
/// as one list instead of a mix of bare text and decorated lines.
abstract final class Glyph {
  /// Icon + trailing space, or '' on a terminal that can't render ANSI (the
  /// icons ride on color codes that would otherwise print as bare symbols).
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

/// A single in-progress phase.
class Step {
  Step._(this.label) : _watch = Stopwatch()..start() {
    if (Log._fancy) {
      _draw();
      return;
    }
    // No spinner to watch (piped output, a debug console, `--verbose`), so
    // announce the phase up front — otherwise long steps look like a hang.
    Log._logger.stdout('${Glyph.info}$label…');
  }

  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  /// How many trailing output lines stay visible under the spinner.
  static const _tailLines = 3;

  final String label;
  final Stopwatch _watch;
  Timer? _timer;
  int _tick = 0;
  bool _closed = false;

  /// Completed tail lines (most recent last), plus the partial line still
  /// being written — kept separate so a prompt without a trailing newline is
  /// still shown.
  final List<String> _tail = [];
  String _partial = '';

  /// Lines occupied by the last render, so the next one knows how far up to go.
  int _drawn = 0;

  /// Feed subprocess output into the collapsing grey tail under the spinner.
  /// Accepts arbitrary chunks — partial lines are fine. Off a fancy TTY the
  /// lines go to trace instead (visible only with `--verbose`).
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

  /// Replace the spinner with a success line, discarding the tail.
  void done([String? message]) =>
      _close(Glyph.ok, message ?? label, timed: true);

  /// Replace the spinner with a failure line, discarding the tail.
  void fail([String? message]) => _close(Glyph.bad, message ?? label);

  /// Repaint the spinner and its tail as one block, in place.
  void _draw() {
    // A `logStatus` mid-step erases the block and kills the timer; a later log
    // line should bring the spinner back rather than leave it frozen.
    _timer ??= Timer.periodic(const Duration(milliseconds: 80), (_) => _draw());
    final tail = _visibleTail();
    final frame = _frames[_tick++ % _frames.length];
    stdout.write(
      renderBlock(
        head: '${Log.ansi.cyan}$frame${Log.ansi.none} $label',
        tail: [for (final line in tail) Log.ansi.subtle(_fit(line))],
        previousRows: _drawn,
      ),
    );
    _drawn = 1 + tail.length;
  }

  /// The escape sequence that repaints a [head] line plus indented [tail] lines
  /// over the [previousRows] rows drawn last time.
  ///
  /// The cursor starts and ends on the row just below the block, so the next
  /// call moves up exactly [previousRows]. Pure so it can be unit-tested
  /// without a terminal.
  static String renderBlock({
    required String head,
    required List<String> tail,
    required int previousRows,
  }) {
    final buf = StringBuffer();
    // Back to the top of the block we drew last time.
    if (previousRows > 0) buf.write('\x1B[${previousRows}A');
    buf.write('\r$head\x1B[K\n');
    for (final line in tail) {
      buf.write('\r    $line\x1B[K\n');
    }
    // The block only ever grows, so nothing stale can be left below it.
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

  /// Truncate to the terminal width: a wrapped line would break the cursor-up
  /// arithmetic and leave garbage on screen.
  static String _fit(String line) {
    final max = (stdout.hasTerminal ? stdout.terminalColumns : 80) - 6;
    if (max < 8 || line.length <= max) return line;
    return '${line.substring(0, max - 1)}…';
  }

  /// Stop animating and blank the whole block. Idempotent; does NOT close the
  /// step, so a later [done]/[fail] still reports on a fresh line.
  void _erase() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    if (!Log._fancy) return;
    // Up to the top of the block, then clear everything below the cursor.
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
