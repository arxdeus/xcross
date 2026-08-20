import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/src/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
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
    // App Store Connect has no App Groups resource, so the client reaches
    // them over the legacy developerservices2 protocol, authenticated with
    // the same API key JWT. These tests pin the host, the auth header and
    // the team id lookup that protocol needs.
    Map<String, dynamic> bundlePage(String seedId) => {
      'data': [
        {
          'id': 'APP',
          'attributes': {
            'identifier': 'com.example.App',
            'name': 'App',
            'seedId': seedId,
          },
        },
      ],
    };

    String legacyPlist(Map<String, Object?> body) =>
        PropertyListSerialization.stringWithPropertyList({
          'resultCode': 0,
          ...body,
        });

    test('looks a group up on developerservices2 with the key', () async {
      final urls = <String>[];
      String? authorization;
      final client = AscClient(
        credentials,
        httpClient: MockClient((request) async {
          urls.add(request.url.toString());
          if (request.url.host == 'api.appstoreconnect.apple.com') {
            return http.Response(jsonEncode(bundlePage('TEAMSEED')), 200);
          }
          authorization = request.headers['Authorization'];
          final body =
              PropertyListSerialization.propertyListWithString(request.body)
                  as Map;
          // The legacy protocol needs the team explicitly; an API key has
          // none of its own, so it comes from the bundle id's seedId.
          expect(body['teamId'], 'TEAMSEED');
          return http.Response(
            legacyPlist({
              'applicationGroupList': [
                {
                  'applicationGroup': 'GROUPID',
                  'identifier': 'group.com.example.Shared',
                  'name': 'Shared',
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      final group = await client.findAppGroup('group.com.example.Shared');
      expect(group?.id, 'GROUPID');
      expect(group?.identifier, 'group.com.example.Shared');
      expect(authorization, startsWith('Bearer '));
      expect(
        urls.last,
        'https://developerservices2.apple.com/services/QH65B2/'
        'ios/listApplicationGroups.action?clientId=XABBG36SBA',
      );
    });

    test('caches the team id across calls', () async {
      var seedLookups = 0;
      final client = AscClient(
        credentials,
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.appstoreconnect.apple.com') {
            seedLookups++;
            return http.Response(jsonEncode(bundlePage('TEAMSEED')), 200);
          }
          return http.Response(
            legacyPlist({'applicationGroupList': <Object>[]}),
            200,
          );
        }),
      );
      addTearDown(client.close);

      await client.findAppGroup('group.com.example.Shared');
      await client.findAppGroup('group.com.example.Other');
      expect(seedLookups, 1);
    });

    test('registers a group over the legacy protocol', () async {
      final client = AscClient(
        credentials,
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.appstoreconnect.apple.com') {
            return http.Response(jsonEncode(bundlePage('TEAMSEED')), 200);
          }
          expect(request.url.path, endsWith('addApplicationGroup.action'));
          final body =
              PropertyListSerialization.propertyListWithString(request.body)
                  as Map;
          expect(body['identifier'], 'group.com.example.Shared');
          // Apple rejects punctuation in group names.
          expect(body['name'], 'xcross group com example Shared');
          return http.Response(
            legacyPlist({
              'applicationGroup': {
                'applicationGroup': 'NEWID',
                'identifier': 'group.com.example.Shared',
                'name': 'xcross group com example Shared',
              },
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      final group = await client.registerAppGroup(
        identifier: 'group.com.example.Shared',
        name: 'xcross group.com.example.Shared',
      );
      expect(group.id, 'NEWID');
    });

    test('enables the capability and links the group', () async {
      final actions = <String>[];
      final client = AscClient(
        credentials,
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.appstoreconnect.apple.com') {
            return http.Response(jsonEncode(bundlePage('TEAMSEED')), 200);
          }
          final action = request.url.pathSegments.last;
          actions.add(action);
          final body =
              PropertyListSerialization.propertyListWithString(request.body)
                  as Map;
          expect(body['appIdId'], 'APP');
          if (action == 'updateAppId.action') {
            // Apple's internal feature key for App Groups.
            expect(body['APG3427HIY'], true);
          } else {
            expect(body['applicationGroups'], ['GROUPID']);
          }
          return http.Response(legacyPlist(const {}), 200);
        }),
      );
      addTearDown(client.close);

      await client.assignAppGroups(
        bundleIdResourceId: 'APP',
        appGroupResourceIds: ['GROUPID'],
      );
      // The feature flag has to come first: it is what makes Apple issue an
      // application-groups entitlement at all.
      expect(actions, [
        'updateAppId.action',
        'assignApplicationGroupToAppId.action',
      ]);
    });

    test('surfaces a rejected key from the legacy host', () async {
      final client = AscClient(
        credentials,
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.appstoreconnect.apple.com') {
            return http.Response(jsonEncode(bundlePage('TEAMSEED')), 200);
          }
          // What developerservices2 really answers for an unknown key: the
          // same text api.appstoreconnect.apple.com uses.
          return http.Response(
            PropertyListSerialization.stringWithPropertyList({
              'resultCode': 403,
              'userString':
                  'Make sure a bearer token was provided, it is properly '
                  'configured and signed, and it has not expired.',
            }),
            403,
          );
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.findAppGroup('group.com.example.Shared'),
        throwsA(
          isA<AppleApiError>()
              .having((error) => error.statusCode, 'status', 403)
              .having(
                (error) => error.toString(),
                'message',
                contains('properly configured and signed'),
              ),
        ),
      );
    });

    test('explains a team with no bundle ids to read a seedId from', () async {
      final client = AscClient(
        credentials,
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode({'data': <Object>[]}), 200),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.findAppGroup('group.com.example.Shared'),
        throwsA(
          isA<AppleError>().having(
            (error) => error.toString(),
            'message',
            contains('Could not determine the team id'),
          ),
        ),
      );
    });
  });
}
