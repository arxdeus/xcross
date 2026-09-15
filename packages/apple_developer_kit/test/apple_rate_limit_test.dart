import 'dart:io';

import 'package:apple_developer_kit/src/apple_http_client.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_headers.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_operation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  for (final operation in ['init', 'complete', 'apptokens']) {
    test('$operation sends akd on the actual GSA request', () async {
      final client = MockClient((request) async {
        expect(request.persistentConnection, isFalse);
        expect(request.headers['X-MMe-Client-Info'], anisetteClientInfo);
        expect(
          request.headers['X-MMe-Client-Info'],
          contains('com.apple.akd/1.0'),
        );
        expect(
          request.headers['X-MMe-Client-Info'],
          isNot(contains('com.apple.dt.Xcode')),
        );
        return http.Response('<html>rate limited</html>', 429);
      });
      addTearDown(client.close);
      await expectLater(
        GrandSlamOperation.postGrandSlamOperation(
          httpClient: client,
          gsService: 'https://gsa.apple.com/grandslam/GsService2',
          operation: operation,
          username: 'test@example.com',
          fetchAnisetteHeaders: () async =>
              AnisetteHeaders.buildAnisetteHeaders(
                oneTimePassword: 'otp',
                machineIdentifier: 'mid',
                routingInfo: '123',
                localUserUid: 'test-device',
              ),
          extraParams: const {},
        ),
        throwsA(isA<AppleRateLimitError>()),
      );
    });
  }

  final now = DateTime.utc(2026, 9, 15, 0, 0, 0, 500);

  AppleRateLimitError errorFor(String? retryAfter) {
    try {
      AppleHttp.checkRateLimit(
        http.Response(
          '<html>private response</html>',
          429,
          headers: {if (retryAfter != null) 'retry-after': retryAfter},
        ),
        operation: 'test operation',
        now: now,
      );
    } on AppleRateLimitError catch (error) {
      return error;
    }
    throw StateError('Expected a rate limit error');
  }

  test('parses Retry-After seconds without leaking response contents', () {
    final error = errorFor(' 120 ');
    expect(error.retryAfter, const Duration(seconds: 120));
    expect(error.operation, 'test operation');
    expect(error.message, contains('HTTP 429'));
    expect(error.message, contains('Wait at least 120 seconds'));
    expect(error.message, isNot(contains('private response')));
    expect(error.message, contains('not retried'));
  });

  test('accepts zero seconds', () {
    expect(errorFor('0').retryAfter, Duration.zero);
  });

  test('parses HTTP date and rounds up rather than retrying early', () {
    expect(
      errorFor(HttpDate.format(DateTime.utc(2026, 9, 15, 0, 2))).retryAfter,
      const Duration(seconds: 120),
    );
  });

  for (final value in <String?>[
    null,
    '',
    'nonsense',
    '-1',
    '1.5',
    '9999999999999999999999999999999999',
    '2147483648',
    HttpDate.format(now.subtract(const Duration(minutes: 1))),
  ]) {
    test('unknown cooldown for unusable Retry-After: $value', () {
      final error = errorFor(value);
      expect(error.retryAfter, isNull);
      expect(error.message, contains('did not provide a usable Retry-After'));
    });
  }

  test('does not change non-429 responses', () {
    for (final status in [200, 401, 403, 500, 503]) {
      AppleHttp.checkRateLimit(http.Response('', status), operation: 'test');
    }
  });

  for (final operation in [
    'endpoint lookup',
    'midStartProvisioning',
    'midFinishProvisioning',
    'o=init',
    'o=complete',
    'o=apptokens',
    'two-factor verification',
  ]) {
    test(
      '$operation reports throttling and sends exactly one request',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return http.Response(
            '<html>Too Many Requests</html>',
            429,
            headers: {'retry-after': '60'},
          );
        });
        addTearDown(client.close);
        await expectLater(
          GrandSlamEndpoints.sendGrandSlamRequest(
            client,
            method: operation == 'endpoint lookup' ? 'GET' : 'POST',
            url: 'https://gsa.apple.com/test?secret=hidden',
            operation: operation,
          ),
          throwsA(
            isA<AppleRateLimitError>()
                .having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 60),
                )
                .having((e) => e.message, 'context', contains(operation))
                .having(
                  (e) => e.message,
                  'host',
                  contains('gsa.apple.com/test'),
                )
                .having(
                  (e) => e.message,
                  'redaction',
                  isNot(contains('hidden')),
                ),
          ),
        );
        expect(requests, 1);
      },
    );
  }
}
