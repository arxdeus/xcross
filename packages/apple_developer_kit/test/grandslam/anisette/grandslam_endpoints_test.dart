// Tests for [GrandSlamEndpoints]/[fetchGrandSlamEndpoints]: plist
// encode/decode of the lookup response shape, and the lookup HTTP call
// (mocked - see task note re: no real network in this test suite).
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/grandslam_endpoints.dart';

/// A hand-constructed lookup response plist, matching the exact shape
/// documented in the task spec: a top-level `urls` dict, no `Status`/
/// `Response` envelope (unlike the provisioning POSTs).
const _lookupResponsePlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>urls</key>
\t<dict>
\t\t<key>gsService</key>
\t\t<string>https://gsa.apple.com/grandslam/GsService2</string>
\t\t<key>secondaryAuth</key>
\t\t<string>https://gsa.apple.com/auth/secondary</string>
\t\t<key>trustedDeviceSecondaryAuth</key>
\t\t<string>https://gsa.apple.com/auth/trusted-device</string>
\t\t<key>validateCode</key>
\t\t<string>https://gsa.apple.com/grandslam/GsService2/validate</string>
\t\t<key>midStartProvisioning</key>
\t\t<string>https://gsa.apple.com/grandslam/GsService2/midStartProvisioning</string>
\t\t<key>midFinishProvisioning</key>
\t\t<string>https://gsa.apple.com/grandslam/GsService2/midFinishProvisioning</string>
\t</dict>
</dict>
</plist>
''';

void main() {
  group('plist round-trip', () {
    test('decodes a hand-built urls-shaped lookup response', () {
      final decoded = PropertyListSerialization.propertyListWithString(
        _lookupResponsePlist,
      );
      expect(decoded, isA<Map<Object?, Object?>>());
      final urls =
          (decoded as Map<Object?, Object?>)['urls']! as Map<Object?, Object?>;
      expect(
        urls['midStartProvisioning'],
        'https://gsa.apple.com/grandslam/GsService2/midStartProvisioning',
      );

      final endpoints = GrandSlamEndpoints.fromPlistUrls(urls.cast());
      expect(endpoints.gsService, 'https://gsa.apple.com/grandslam/GsService2');
      expect(endpoints.secondaryAuth, 'https://gsa.apple.com/auth/secondary');
      expect(
        endpoints.trustedDeviceSecondaryAuth,
        'https://gsa.apple.com/auth/trusted-device',
      );
      expect(
        endpoints.validateCode,
        'https://gsa.apple.com/grandslam/GsService2/validate',
      );
      expect(
        endpoints.midStartProvisioning,
        'https://gsa.apple.com/grandslam/GsService2/midStartProvisioning',
      );
      expect(
        endpoints.midFinishProvisioning,
        'https://gsa.apple.com/grandslam/GsService2/midFinishProvisioning',
      );
    });

    test('encoding then decoding a urls dict round-trips exactly', () {
      final original = {
        'urls': {
          'gsService': 'https://gsa.apple.com/gs',
          'secondaryAuth': 'https://gsa.apple.com/secondary',
          'trustedDeviceSecondaryAuth': 'https://gsa.apple.com/trusted',
          'validateCode': 'https://gsa.apple.com/validate',
          'midStartProvisioning': 'https://gsa.apple.com/start',
          'midFinishProvisioning': 'https://gsa.apple.com/finish',
        },
      };
      final xml = PropertyListSerialization.stringWithPropertyList(original);
      expect(xml, contains('<key>midStartProvisioning</key>'));
      expect(xml, contains('https://gsa.apple.com/start'));

      final decoded = PropertyListSerialization.propertyListWithString(xml);
      final endpoints = GrandSlamEndpoints.fromPlistUrls(
        ((decoded as Map)['urls'] as Map).cast(),
      );
      expect(endpoints.midStartProvisioning, 'https://gsa.apple.com/start');
      expect(endpoints.midFinishProvisioning, 'https://gsa.apple.com/finish');
    });

    test('rejects non-Apple or plaintext endpoint URLs', () {
      final urls = {
        'gsService': 'https://evil.example/collect',
        'secondaryAuth': 'https://gsa.apple.com/secondary',
        'trustedDeviceSecondaryAuth': 'https://gsa.apple.com/trusted',
        'validateCode': 'https://gsa.apple.com/validate',
        'midStartProvisioning': 'https://gsa.apple.com/start',
        'midFinishProvisioning': 'https://gsa.apple.com/finish',
      };

      expect(
        () => GrandSlamEndpoints.fromPlistUrls(urls),
        throwsA(isA<Exception>()),
      );
      expect(
        () => validateGrandSlamUrl(
          'http://gsa.apple.com/plaintext',
          field: 'test',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('throws a clear error when a field is missing', () {
      expect(
        () => GrandSlamEndpoints.fromPlistUrls({
          'gsService': 'https://gsa.apple.com/gs',
        }),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('secondaryAuth'),
          ),
        ),
      );
    });
  });

  test('sensitive requests disable and reject redirects', () async {
    final client = MockClient((request) async {
      expect(request.followRedirects, isFalse);
      return http.Response(
        '',
        302,
        headers: {'location': 'https://evil.test'},
        isRedirect: true,
      );
    });

    await expectLater(
      sendGrandSlamRequest(
        client,
        method: 'POST',
        url: 'https://gsa.apple.com/gs',
        operation: 'test',
        body: 'secret',
      ),
      throwsA(isA<Exception>()),
    );
  });

  group('fetchGrandSlamEndpoints', () {
    test('performs a GET (no body) and decodes the response', () async {
      http.Request? seenRequest;
      final client = MockClient((request) async {
        seenRequest = request;
        return http.Response(_lookupResponsePlist, 200);
      });

      final endpoints = await fetchGrandSlamEndpoints(
        client,
        headers: const {'X-Mme-Device-Id': 'test-device'},
      );

      expect(seenRequest!.method, 'GET');
      expect(
        seenRequest!.url.toString(),
        'https://gsa.apple.com/grandslam/GsService2/lookup',
      );
      expect(seenRequest!.headers['X-Mme-Device-Id'], 'test-device');
      expect(
        endpoints.midFinishProvisioning,
        'https://gsa.apple.com/grandslam/GsService2/midFinishProvisioning',
      );
    });

    test('throws on a non-2xx response', () async {
      final client = MockClient((request) async => http.Response('', 500));
      await expectLater(
        () => fetchGrandSlamEndpoints(client, headers: const {}),
        throwsA(isA<Exception>()),
      );
    });

    test('throws a clear error when "urls" is missing', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<?xml version="1.0" encoding="UTF-8"?> '
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"> '
          '<plist version="1.0"><dict/></plist>',
          200,
        ),
      );
      await expectLater(
        () => fetchGrandSlamEndpoints(client, headers: const {}),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('urls'),
          ),
        ),
      );
    });
  });
}
