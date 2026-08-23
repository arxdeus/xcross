import 'dart:io';

import 'package:cli_kit/src/errors.dart';
import 'package:cli_kit/src/progress.dart';
import 'package:path/path.dart' as p;

/// Groups file-download helpers.
abstract final class Downloader {
  static Future<HttpClientResponse> _openStream(
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
          throw CliError(
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
    throw CliError(
      'download failed after $maxAttempts attempts: $url'
      '${lastError == null ? '' : ' ($lastError)'}',
    );
  }

  /// Streams [url] to [dest] with retries and a live progress line.
  static Future<void> downloadToFile(
    String url,
    File dest, {
    int maxAttempts = 4,
    Duration retryDelay = const Duration(seconds: 2),
    String? label,
  }) async {
    final client = HttpClient();
    ProgressBar? reporter;
    try {
      final response = await _openStream(
        client,
        url,
        maxAttempts: maxAttempts,
        retryDelay: retryDelay,
      );
      await dest.parent.create(recursive: true);
      reporter = ProgressBar(
        label ?? _labelFromUrl(url),
        total: response.contentLength,
      );
      final sink = dest.openWrite();
      try {
        await sink.addStream(
          response.map((chunk) {
            reporter!.add(chunk.length);
            return chunk;
          }),
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
      reporter.finish();
    } catch (_) {
      reporter?.fail();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static String _labelFromUrl(String url) {
    try {
      return p.url.basename(Uri.parse(url).path);
    } catch (_) {
      return url;
    }
  }
}
