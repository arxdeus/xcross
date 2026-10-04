// Opt-in real Apple transport check. Sends only two public endpoint-bag GETs.
// Never loads account credentials, ADI libraries or persisted Anisette state.
import 'dart:io';

import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/shared/http/apple_http_client.dart';
import 'package:apple_developer_kit/src/shared/grandslam/anisette/anisette_headers.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real GrandSlam lookup uses a fresh TLS connection for each request',
    () async {
      final connections = CountingConnections();
      await HttpOverrides.runWithHttpOverrides(() async {
        // Same client factory and request sender used by xcross auth.
        final client = AppleHttpClientFactory(
          createSecurityContext: () => SecurityContext(withTrustedRoots: true),
          createHttpClient: (context) => HttpClient(context: context),
        ).createClient();
        addTearDown(client.close);
        for (var i = 0; i < 2; i++) {
          final endpoints = await GrandSlamEndpoints.fetchGrandSlamEndpoints(
            client,
            headers: AnisetteHeaders.buildAnisetteLookupHeaders(
              const AnisetteState(
                localUserUid: '9A9023E0-923A-4A84-A76D-41EB56C3F1B2',
              ),
              localeName: 'en_US',
            ),
          );
          expect(Uri.parse(endpoints.gsService).scheme, 'https');
          expect(Uri.parse(endpoints.gsService).host, endsWith('.apple.com'));
        }
      }, connections);
      expect(
        connections.opened,
        2,
        reason: 'Sequential GSA requests must not reuse an idle connection',
      );
    },
    skip: Platform.environment['XCROSS_LIVE_GSA_TRANSPORT'] != '1'
        ? 'Set XCROSS_LIVE_GSA_TRANSPORT=1 for two credential-free Apple GETs'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

@internal
final class CountingConnections extends HttpOverrides {
  int opened = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        opened++;
        // A custom connection factory supplies TLS itself for direct HTTPS.
        if (uri.scheme == 'https' && proxyHost == null) {
          return SecureSocket.startConnect(
            uri.host,
            uri.port,
            context: context,
          );
        }
        return Socket.startConnect(
          proxyHost ?? uri.host,
          proxyPort ?? uri.port,
        );
      };
  }
}
