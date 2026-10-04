import 'dart:io';
import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

@internal
abstract final class AppleHttp {
  /// Surface throttling before attempting to decode a JSON/plist body. Apple's
  /// edge may return HTML instead. Never include response bodies or credentials.
  static void checkRateLimit(
    http.Response response, {
    required String operation,
    DateTime? now,
  }) {
    if (response.statusCode != 429) return;
    final value = response.headers['retry-after']?.trim();
    Duration? retryAfter;
    if (value != null) {
      if (RegExp(r'^\d+$').hasMatch(value)) {
        final seconds = int.tryParse(value);
        // Keep untrusted integers within Duration's representable range.
        if (seconds != null && seconds <= 2147483647) {
          retryAfter = Duration(seconds: seconds);
        }
      } else {
        try {
          final remaining = HttpDate.parse(
            value,
          ).difference((now ?? DateTime.now()).toUtc());
          if (!remaining.isNegative) {
            retryAfter = Duration(
              seconds: (remaining.inMicroseconds / 1000000).ceil(),
            );
          }
        } on HttpException {
          // Missing/malformed/past Retry-After means the cooldown is unknown.
        }
      }
    }
    throw AppleRateLimitError(operation: operation, retryAfter: retryAfter);
  }
}
