import 'dart:io';

import 'package:cli_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/progress/progress.dart';
import 'package:path/path.dart' as p;

final class Downloader {
  Downloader({required HttpClient Function() createClient, required this.log})
    : _createClient = createClient;

  final HttpClient Function() _createClient;
  final Log log;
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
      } on Object catch (e) {
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

  Future<void> downloadToFile(
    String url,
    File dest, {
    int maxAttempts = 4,
    Duration retryDelay = const Duration(seconds: 2),
    String? label,
  }) async {
    if (maxAttempts < 1) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be positive');
    }
    final client = _createClient();
    ProgressBar? reporter;
    var transferFailed = false;
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
        log: log,
        total: response.contentLength,
      );
      final sink = dest.openWrite();
      var failed = false;
      try {
        await sink.addStream(
          response.map((chunk) {
            reporter!.add(chunk.length);
            return chunk;
          }),
        );
        await sink.flush();
      } on Object {
        failed = true;
        rethrow;
      } finally {
        try {
          await sink.close();
        } on Object {
          if (!failed) rethrow;
        }
      }
      reporter.finish();
    } catch (error, stack) {
      transferFailed = true;
      try {
        reporter?.fail();
      } finally {
        Error.throwWithStackTrace(error, stack);
      }
    } finally {
      try {
        client.close(force: true);
      } on Object {
        if (!transferFailed) rethrow;
      }
    }
  }

  static String _labelFromUrl(String url) {
    try {
      return p.url.basename(Uri.parse(url).path);
    } on FormatException {
      return url;
    }
  }
}
