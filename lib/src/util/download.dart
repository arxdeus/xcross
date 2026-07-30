import 'dart:io';

import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Open [url] with retry, following redirects, throwing [XcrossError] on any
/// non-2xx status. Returns the live, undrained response stream.
Future<HttpClientResponse> _openStream(
  HttpClient client,
  String url, {
  required int maxAttempts,
  required Duration retryDelay,
}) async {
  Object? lastError;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = true;
      request.maxRedirects = 10;
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw XcrossError(
          'download failed: HTTP ${response.statusCode} for $url',
        );
      }
      return response;
    } catch (e) {
      lastError = e;
      if (attempt == maxAttempts) break;
      await Future<void>.delayed(retryDelay);
    }
  }
  throw XcrossError(
    'download failed after $maxAttempts attempts: $url'
    '${lastError == null ? '' : ' ($lastError)'}',
  );
}

/// Stream [url] to [dest] (pure Dart; replaces `curl -L --fail -o`).
///
/// Shows a live download-progress line on stdout (bytes, percent, rate). Pass
/// [label] to override the display name (defaults to the URL's file name).
Future<void> downloadToFile(
  String url,
  File dest, {
  int maxAttempts = 4,
  Duration retryDelay = const Duration(seconds: 2),
  String? label,
}) async {
  final client = HttpClient();
  try {
    final response = await _openStream(
      client,
      url,
      maxAttempts: maxAttempts,
      retryDelay: retryDelay,
    );
    await dest.parent.create(recursive: true);
    final reporter = _DownloadProgress(
      label ?? _labelFromUrl(url),
      response.contentLength,
    );
    final sink = dest.openWrite();
    try {
      await sink.addStream(_withProgress(response, reporter));
      await sink.flush();
    } finally {
      await sink.close();
    }
    reporter.finish();
  } finally {
    client.close(force: true);
  }
}

/// Wrap [source] so [reporter] observes byte counts without changing the
/// stream's contents. Returns the source unchanged when [reporter] is null.
Stream<List<int>> _withProgress(
  Stream<List<int>> source,
  _DownloadProgress reporter,
) {
  return source.map((chunk) {
    reporter.add(chunk.length);
    return chunk;
  });
}

/// Best-effort file-name from [url] for display in the progress line.
String _labelFromUrl(String url) {
  try {
    final segs = Uri.parse(url).pathSegments;
    for (var i = segs.length - 1; i >= 0; i--) {
      if (segs[i].isNotEmpty) return segs[i];
    }
  } catch (_) {}
  return url;
}

/// Live download-progress line. Prints `\r`-overwriting updates on a TTY
/// (bytes / total, percent, rate); on a non-TTY (piped/logged) it emits
/// occasional plain lines so logs stay readable. [total] is `-1` when the
/// server did not send `Content-Length`.
class _DownloadProgress {
  _DownloadProgress(this.label, this.total)
      : _stopwatch = Stopwatch()..start(),
        _isTty = stdout.hasTerminal {
    // We draw with raw `\r`; a live spinner on the same line would fight us.
    stopStep();
  }

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
    final elapsedMs = _stopwatch.elapsedMilliseconds;
    if (_isTty) {
      // Throttle TTY redraws to ~10 Hz.
      if (elapsedMs - _lastRenderMs < 100) return;
      _lastRenderMs = elapsedMs;
      _render(elapsedMs);
    } else if (total > 0) {
      // Non-TTY: log a fresh line every ~10% so piped logs stay readable.
      final percent = (_received * 100 ~/ total).clamp(0, 100);
      if (percent >= _lastLoggedPercent + 10) {
        _lastLoggedPercent = percent - (percent % 10);
        logStatus('${Glyph.download} $label '
            '${ansi.subtle('$percent%  ${_fmtBytes(_received)}'
                ' / ${_fmtBytes(total)}')}');
      }
    }
  }

  void finish() {
    if (_done) return;
    _done = true;
    _stopwatch.stop();
    if (_isTty) stdout.write('\r${' '.padRight(96)}\r');
    logDone(label, _fmtBytes(_received));
  }

  static const _barWidth = 24;

  void _render(int elapsedMs) {
    final rate = elapsedMs > 0 ? _received * 1000 / elapsedMs : 0.0;
    final buf = StringBuffer('${Glyph.download} ${label.padRight(24)}');
    if (total > 0) {
      final fraction = (_received / total).clamp(0.0, 1.0);
      final filled = (fraction * _barWidth).round();
      buf.write('${ansi.cyan}${'━' * filled}${ansi.none}');
      buf.write(ansi.subtle('━' * (_barWidth - filled)));
      buf.write(' ${(fraction * 100).round()}%'.padLeft(5));
      buf.write(ansi.subtle('  ${_fmtBytes(_received)} / ${_fmtBytes(total)}'));
    } else {
      buf.write(_fmtBytes(_received));
    }
    buf.write(ansi.subtle('  ${_fmtBytes(rate.round())}/s'));
    // `\r` + right-pad so leftover chars from a longer prior line are erased.
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
