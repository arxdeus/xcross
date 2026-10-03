import 'dart:async';
import 'dart:io';

import 'package:xcross/src/flutter/errors.dart';

abstract interface class SwiftPmArchiveTransport {
  Future<void> download(Uri url, File destination, int maximumBytes);
}

final class HttpSwiftPmArchiveTransport implements SwiftPmArchiveTransport {
  const HttpSwiftPmArchiveTransport({required this.createClient});
  final HttpClient Function() createClient;
  static const downloadConnectTimeout = Duration(seconds: 60);
  static const downloadStallTimeout = Duration(minutes: 2);
  static const downloadTotalTimeout = Duration(minutes: 15);
  static const _archiveByteLimitMessage =
      'SwiftPM binary artifact exceeds compressed archive byte limit';
  @override
  Future<void> download(Uri url, File destination, int maximumBytes) =>
      downloadArchive(url, destination, maximumBytes);
  Future<void> downloadArchive(
    Uri url,
    File destination,
    int maximumBytes, {
    Duration connectTimeout = downloadConnectTimeout,
    Duration stallTimeout = downloadStallTimeout,
    Duration totalTimeout = downloadTotalTimeout,
  }) async {
    final client = createClient()
      ..connectionTimeout = connectTimeout
      ..idleTimeout = stallTimeout;
    IOSink? output;
    try {
      final request = await client
          .getUrl(url)
          .timeout(
            connectTimeout,
            onTimeout: () => throw TimeoutException(
              'timed out connecting to $url after $connectTimeout',
            ),
          );
      final response = await request.close().timeout(
        connectTimeout,
        onTimeout: () => throw TimeoutException(
          'timed out waiting for a response from $url after $connectTimeout',
        ),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode} while downloading archive',
          uri: url,
        );
      }
      if (response.contentLength > maximumBytes) {
        throw FlutterBuildError(_archiveByteLimitMessage);
      }
      await destination.parent.create(recursive: true);
      output = destination.openWrite();
      var downloadedBytes = 0;
      final total = Stopwatch()..start();
      final chunks = response.timeout(
        stallTimeout,
        onTimeout: (sink) => sink.addError(
          TimeoutException(
            'download of $url stalled for $stallTimeout after '
            '$downloadedBytes bytes',
          ),
        ),
      );
      await for (final chunk in chunks) {
        if (downloadedBytes + chunk.length > maximumBytes) {
          throw FlutterBuildError(_archiveByteLimitMessage);
        }
        if (total.elapsed > totalTimeout) {
          throw TimeoutException(
            'download of $url exceeded $totalTimeout after '
            '$downloadedBytes bytes',
          );
        }
        output.add(chunk);
        downloadedBytes += chunk.length;
      }
      await output.flush();
    } finally {
      client.close(force: true);
      await output?.close();
      if (destination.existsSync() && destination.lengthSync() > maximumBytes) {
        await destination.delete();
      }
    }
  }
}
