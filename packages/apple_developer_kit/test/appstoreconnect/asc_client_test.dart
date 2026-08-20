import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/src/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late AscCredentials credentials;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_asc_client-');
    // A throwaway EC keypair stands in for a real Apple .p8 key: these tests
    // never reach Apple, they only check what the client sends and accepts.
    final keyPair = CryptoUtils.generateEcKeyPair();
    final keyFile = File('${tmp.path}/AuthKey_TESTKEY123.p8');
    await keyFile.writeAsString(
      CryptoUtils.encodeEcPrivateKeyToPem(keyPair.privateKey as ECPrivateKey),
    );
    credentials = AscCredentials(
      issuerId: 'issuer-1234',
      keyId: 'TESTKEY123',
      privateKeyPath: keyFile.path,
    );
  });

  tearDown(() => tmp.delete(recursive: true));

  Map<String, dynamic> bundle(String id, String identifier) => {
    'id': id,
    'attributes': {'identifier': identifier, 'name': identifier},
  };

  group('findBundleId', () {
    test('picks the exact match out of a prefix-matched page', () async {
      // Apple treats filter[identifier] as a prefix match, so an app's query
      // also returns its extensions. Taking the first row would sign the app
      // with an extension's App ID.
      final client = AscClient(
        credentials,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/v1/bundleIds');
          return http.Response(
            jsonEncode({
              'data': [
                bundle('EXT1', 'com.example.App.ActionExtension'),
                bundle('APP', 'com.example.App'),
                bundle('EXT2', 'com.example.App.Share-Extension'),
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      final found = await client.findBundleId('com.example.App');

      expect(found?.id, 'APP');
      expect(found?.identifier, 'com.example.App');
    });

    test('resolves an extension id that shares the app prefix', () async {
      final client = AscClient(
        credentials,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                bundle('EXT1', 'com.example.App.ActionExtension'),
                bundle('EXT2', 'com.example.App.Share-Extension'),
              ],
            }),
            200,
          ),
        ),
      );
      addTearDown(client.close);

      final found = await client.findBundleId(
        'com.example.App.Share-Extension',
      );

      expect(found?.id, 'EXT2');
    });

    test('returns null when only prefix neighbours come back', () async {
      final client = AscClient(
        credentials,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [bundle('EXT1', 'com.example.App.ActionExtension')],
            }),
            200,
          ),
        ),
      );
      addTearDown(client.close);

      // Registering must not be skipped just because a longer id exists.
      expect(await client.findBundleId('com.example.App'), isNull);
    });
  });

  group('App Groups', () {
    // App Groups are unreachable with an API key, and this is a property of
    // Apple's APIs rather than a transient failure. Each route was checked
    // against a live key: api.appstoreconnect.apple.com 404s /appGroups, the
    // APP_GROUPS capability cannot name a group, the resulting profile grants
    // an empty application-groups array, and developerservices2 (which does
    // expose App Groups) refuses API keys outright. So the client must report
    // the limitation without spending a request on it.
    test('reports App Groups as unsupported without any request', () async {
      var called = false;
      final client = AscClient(
        credentials,
        httpClient: MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.findAppGroup('group.com.example.Shared'),
        throwsA(isA<AppGroupsUnsupported>()),
      );
      await expectLater(
        client.registerAppGroup(
          identifier: 'group.com.example.Shared',
          name: 'Shared',
        ),
        throwsA(isA<AppGroupsUnsupported>()),
      );
      await expectLater(
        client.assignAppGroups(
          bundleIdResourceId: 'APP',
          appGroupResourceIds: const ['GROUP'],
        ),
        throwsA(isA<AppGroupsUnsupported>()),
      );
      expect(called, isFalse, reason: 'no API can satisfy this');
    });

    test('names the Apple ID sign-in that does work', () async {
      final client = AscClient(
        credentials,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(client.close);

      await expectLater(
        client.findAppGroup('group.com.example.Shared'),
        throwsA(
          isA<AppGroupsUnsupported>().having(
            (error) => error.toString(),
            'message',
            contains('xcross auth --apple-id'),
          ),
        ),
      );
    });
  });
}
