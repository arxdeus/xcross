import 'dart:io';

import 'package:cli_kit/src/logging.dart';

/// How a progress amount reads to a human.
enum ProgressUnit {
  /// Byte counts, rendered as `3.2 GB`.
  bytes,

  /// Plain item counts, rendered as `12,431`.
  items,
}

/// A live progress line: a `\r`-overwriting bar on a TTY, sparse plain lines
/// otherwise.
///
/// [total] is negative while the size is unknown, in which case only the
/// running amount and rate are shown.
final class ProgressBar {
  ProgressBar(
    this.label, {
    this.total = -1,
    this.unit = ProgressUnit.bytes,
    String? glyph,
  }) : _glyph = glyph ?? Glyph.download,
       _stopwatch = Stopwatch()..start(),
       _isTty = stdout.hasTerminal && Log.ansi.useAnsi && !Log.isVerbose {
    Log.stopStep();
  }

  static const _barWidth = 24;
  static const _labelWidth = 26;
  static const _renderIntervalMs = 100;

  /// Room the percentage and the `3.2 GB / 12.0 GB` pair need beside the bar.
  static const _amountColumns = 32;

  /// Below this the label stops being padded to a fixed column.
  static const _wideColumns = 78;

  final String label;
  final ProgressUnit unit;
  final String _glyph;
  final Stopwatch _stopwatch;
  final bool _isTty;

  /// The expected final amount; assignable because some sources only report
  /// their size once the first bytes have been decoded.
  int total;

  int _current = 0;
  String _note = '';
  int _lastRenderMs = -_renderIntervalMs;
  int _lastLoggedDecile = -1;
  bool _done = false;

  /// The amount reported so far.
  int get current => _current;

  /// Trailing context shown after the bar, such as `12,431 entries`.
  String get note => _note;

  set note(String value) {
    if (value == _note) return;
    _note = value;
    _report();
  }

  /// Advances the bar by [amount].
  void add(int amount) => update(_current + amount);

  /// Moves the bar to the absolute [amount].
  void update(int amount) {
    _current = amount;
    _report();
  }

  /// Replaces the bar with a `✓` line; [detail] defaults to the final amount.
  void finish([String? detail]) =>
      _close(() => Log.logDone(label, detail ?? _format(_current)));

  /// Replaces the bar with a `✗` line, leaving the error itself to the caller.
  void fail([String? message]) =>
      _close(() => Log.logStatus('${Glyph.bad}${message ?? label}'));

  void _close(void Function() line) {
    if (_done) return;
    _done = true;
    _stopwatch.stop();
    if (_isTty) stdout.write('\r\x1B[K');
    line();
  }

  void _report() {
    if (_done) return;
    if (!_isTty) {
      _logNextDecile();
      return;
    }
    final elapsedMs = _stopwatch.elapsedMilliseconds;
    if (elapsedMs - _lastRenderMs < _renderIntervalMs) return;
    _lastRenderMs = elapsedMs;
    _render(elapsedMs);
  }

  /// Without a terminal there is nothing to overwrite, so progress collapses
  /// to one line every ten percent.
  void _logNextDecile() {
    if (total <= 0) return;
    final percent = (_current * 100 ~/ total).clamp(0, 100);
    if (percent ~/ 10 <= _lastLoggedDecile) return;
    _lastLoggedDecile = percent ~/ 10;
    final detail =
        '$percent%  ${_format(_current)} / ${_format(total)}'
        '${_note.isEmpty ? '' : '  $_note'}';
    Log.logStatus('$_glyph$label ${Log.dim(detail)}');
  }

  void _render(int elapsedMs) {
    final columns = stdout.terminalColumns;
    final buf = StringBuffer();
    var width = 0;
    // Styled text carries invisible escapes, so the column budget is tracked
    // against the plain form.
    void write(String plain, [String? styled]) {
      buf.write(styled ?? plain);
      width += plain.length;
    }

    write('  ', _glyph);
    // The label only claims its full column once the amounts still fit beside
    // it; below that the bar itself shrinks rather than wrapping the line.
    write(columns >= _wideColumns ? label.padRight(_labelWidth) : '$label ');
    if (total > 0) {
      final barWidth = (columns - width - _amountColumns).clamp(8, _barWidth);
      final fraction = (_current / total).clamp(0.0, 1.0);
      final filled = (fraction * barWidth).round();
      write(
        '━' * barWidth,
        '${Log.ansi.cyan}${'━' * filled}${Log.ansi.none}'
        '${Log.dim('━' * (barWidth - filled))}',
      );
      write(' ${(fraction * 100).round()}%'.padLeft(5));
    }

    // Ordered by how much each part tells the user, because a narrow terminal
    // drops everything from the first part that no longer fits.
    final rate = elapsedMs > 0 ? _current * 1000 ~/ elapsedMs : 0;
    final extras = [
      if (total > 0)
        '  ${_format(_current)} / ${_format(total)}'
      else
        '  ${_format(_current)}',
      if (_note.isNotEmpty) '  $_note',
      '  ${_format(rate)}/s',
    ];
    for (final extra in extras) {
      if (width + extra.length > columns - 1) break;
      write(extra, Log.dim(extra));
    }
    stdout.write('\r$buf\x1B[K');
  }

  String _format(int amount) =>
      unit == ProgressUnit.bytes ? formatBytes(amount) : formatCount(amount);

  /// `1536` as `1.5 KB`.
  static String formatBytes(int n) {
    if (n < 1024) return '$n B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = n / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }

  /// `12431` as `12,431`.
  static String formatCount(int n) => n.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
}
