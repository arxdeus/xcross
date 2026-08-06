import 'dart:io';

import 'package:cli_kit/src/logging.dart';

/// Live download-progress line: `\r`-overwriting bar on a TTY, sparse plain
/// lines otherwise. [total] is `-1` when the server sent no `Content-Length`.
final class DownloadProgress {
  DownloadProgress(this.label, this.total)
    : _stopwatch = Stopwatch()..start(),
      _isTty = stdout.hasTerminal {
    Log.stopStep();
  }

  static const _barWidth = 24;
  static const _renderIntervalMs = 100;

  final String label;
  final int total;
  final Stopwatch _stopwatch;
  final bool _isTty;

  int _received = 0;
  int _lastRenderMs = 0;
  int _lastLoggedPercent = -1;
  bool _done = false;

  void add(int bytes) {
    _received += bytes;
    if (_isTty) {
      _renderThrottled();
    } else if (total > 0) {
      _logNextDecile();
    }
  }

  void finish() {
    if (_done) return;
    _done = true;
    _stopwatch.stop();
    if (_isTty) stdout.write('\r${' '.padRight(96)}\r');
    Log.logDone(label, _fmtBytes(_received));
  }

  void _renderThrottled() {
    final elapsedMs = _stopwatch.elapsedMilliseconds;
    if (elapsedMs - _lastRenderMs < _renderIntervalMs) return;
    _lastRenderMs = elapsedMs;
    _render(elapsedMs);
  }

  void _logNextDecile() {
    final percent = (_received * 100 ~/ total).clamp(0, 100);
    if (percent < _lastLoggedPercent + 10) return;
    _lastLoggedPercent = percent - (percent % 10);
    final progress = '$percent%  ${_fmtBytes(_received)} / ${_fmtBytes(total)}';
    Log.logStatus('${Glyph.download} $label ${Log.ansi.subtle(progress)}');
  }

  void _render(int elapsedMs) {
    final rate = elapsedMs > 0 ? _received * 1000 / elapsedMs : 0.0;
    final buf = StringBuffer('${Glyph.download} ${label.padRight(24)}');
    if (total > 0) {
      final fraction = (_received / total).clamp(0.0, 1.0);
      final filled = (fraction * _barWidth).round();
      buf.write('${Log.ansi.cyan}${'━' * filled}${Log.ansi.none}');
      buf.write(Log.ansi.subtle('━' * (_barWidth - filled)));
      buf.write(' ${(fraction * 100).round()}%'.padLeft(5));
      buf.write(
        Log.ansi.subtle('  ${_fmtBytes(_received)} / ${_fmtBytes(total)}'),
      );
    } else {
      buf.write(_fmtBytes(_received));
    }
    buf.write(Log.ansi.subtle('  ${_fmtBytes(rate.round())}/s'));
    stdout.write('\r${buf.toString().padRight(96)}');
  }

  static String _fmtBytes(int n) {
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
}
