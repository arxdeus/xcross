import 'dart:convert';

import 'package:apple_developer_kit/src/appstoreconnect/developer_services_client.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/app_token_exchange.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';

void main() {
  group('DeveloperServicesClient', () {
    test('rewrites GET and keeps the fresh anisette client identity', () async {
      var requestCount = 0;
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM 1',
        fetchAnisetteHeaders: () async => {
          'X-Apple-I-MD': 'fresh',
          'X-MMe-Client-Info': 'fresh-client-info',
        },
        httpClient: MockClient((request) async {
          requestCount++;
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://developerservices2.apple.com/services/v1/bundleIds',
          );
          expect(request.headers['X-HTTP-Method-Override'], 'GET');
          expect(request.headers['X-Apple-I-MD'], 'fresh');
          expect(request.headers['X-MMe-Client-Info'], 'fresh-client-info');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(
            body['urlEncodedQueryParams'],
            'filter%5Bidentifier%5D=com.example.app&teamId=TEAM+1',
          );
          return http.Response(jsonEncode({'data': <Object>[]}), 200);
        }),
      );

      expect(await client.findBundleId('com.example.app'), isNull);
      expect(requestCount, 1);
      client.close();
    });

    test('empty logical GET still sends teamId', () async {
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient((request) async {
          expect(jsonDecode(request.body), {
            'urlEncodedQueryParams': 'teamId=TEAM',
          });
          return http.Response(jsonEncode({'data': <Object>[]}), 200);
        }),
      );

      expect(await client.listDevices(), isEmpty);
      client.close();
    });

    test('follows collection cursor links', () async {
      var call = 0;
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient((request) async {
          call++;
          final query =
              (jsonDecode(request.body) as Map)['urlEncodedQueryParams'];
          if (call == 1) {
            expect(query, 'teamId=TEAM');
            return http.Response(
              jsonEncode({
                'data': [_deviceJson('one')],
                'links': {
                  'next':
                      'https://developerservices2.apple.com/services/v1/devices'
                      '?cursor=NEXT&limit=1',
                },
              }),
              200,
            );
          }
          expect(query, 'cursor=NEXT&limit=1&teamId=TEAM');
          return http.Response(
            jsonEncode({
              'data': [_deviceJson('two')],
            }),
            200,
          );
        }),
      );

      expect((await client.listDevices()).map((device) => device.udid), [
        'one',
        'two',
      ]);
      expect(call, 2);
      client.close();
    });

    test('recovers a device resource after a registration conflict', () async {
      var call = 0;
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient((request) async {
          call++;
          if (call == 1) {
            expect(request.headers['X-HTTP-Method-Override'], isNull);
            return http.Response(
              jsonEncode({
                'errors': [
                  {'detail': 'already registered'},
                ],
              }),
              409,
            );
          }
          expect(request.headers['X-HTTP-Method-Override'], 'GET');
          return http.Response(
            jsonEncode({
              'data': [_deviceJson('UDID')],
            }),
            200,
          );
        }),
      );

      expect(
        (await client.registerDevice(udid: 'UDID', name: 'Phone')).id,
        'device-UDID',
      );
      expect(call, 2);
      client.close();
    });

    test(
      'injects teamId and DEVELOPMENT certificate type and decodes model',
      () async {
        final client = DeveloperServicesClient(
          token: _token(),
          teamId: 'TEAM123',
          fetchAnisetteHeaders: () async => {},
          httpClient: MockClient((request) async {
            expect(
              request.url.toString(),
              'https://developerservices2.apple.com/services/v1/certificates',
            );
            expect(request.headers['X-HTTP-Method-Override'], isNull);
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final data = body['data'] as Map<String, dynamic>;
            final attributes = data['attributes'] as Map<String, dynamic>;
            expect(attributes['certificateType'], 'DEVELOPMENT');
            expect(attributes['csrContent'], 'CSR');
            expect(attributes['teamId'], 'TEAM123');
            return http.Response(
              jsonEncode({
                'data': {
                  'id': 'certificate-id',
                  'type': 'certificates',
                  'attributes': {
                    'certificateContent': 'AQID',
                    'expirationDate': '2030-01-01T00:00:00Z',
                    'serialNumber': 'serial',
                  },
                },
              }),
              201,
            );
          }),
        );

        final certificate = await client.createDevelopmentCertificate(
          csrPem: 'CSR',
        );
        expect(certificate.id, 'certificate-id');
        expect(certificate.certificateContentBase64, 'AQID');
        expect(certificate.serialNumber, 'serial');
        client.close();
      },
    );

    test('findBundleId exact-matches locally', () async {
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'prefix',
                  'attributes': {
                    'identifier': 'com.example.application',
                    'name': 'Prefix',
                  },
                },
                {
                  'id': 'exact',
                  'attributes': {
                    'identifier': 'com.example.app',
                    'name': 'Exact',
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );

      expect((await client.findBundleId('com.example.app'))?.id, 'exact');
      client.close();
    });

    test('rejects expired token before anisette or HTTP', () async {
      var anisetteCalls = 0;
      var httpCalls = 0;
      final client = DeveloperServicesClient(
        token: _token(expired: true),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async {
          anisetteCalls++;
          return {};
        },
        httpClient: MockClient((_) async {
          httpCalls++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(client.listDevices(), throwsA(isA<AppleError>()));
      expect(anisetteCalls, 0);
      expect(httpCalls, 0);
      client.close();
    });

    test('surfaces JSON:API error details', () async {
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'errors': [
                {'title': 'Bad request'},
                {'detail': 'Certificate rejected'},
              ],
            }),
            400,
          ),
        ),
      );

      await expectLater(
        client.listDevices(),
        throwsA(
          isA<AppleError>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('Bad request'), contains('Certificate rejected')),
          ),
        ),
      );
      client.close();
    });
  });

  group('DeveloperServicesClient App Groups', () {
    test('looks a group up over the legacy plist protocol', () async {
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {'X-Apple-I-MD': 'fresh'},
        httpClient: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://developerservices2.apple.com/services/QH65B2/'
            'ios/listApplicationGroups.action?clientId=XABBG36SBA',
          );
          expect(request.headers['X-Apple-I-MD'], 'fresh');
          final body =
              PropertyListSerialization.propertyListWithString(request.body)
                  as Map;
          expect(body['teamId'], 'TEAM');
          expect(body['protocolVersion'], 'QH65B2');
          return http.Response(
            PropertyListSerialization.stringWithPropertyList({
              'resultCode': 0,
              'applicationGroupList': [
                {
                  'applicationGroup': 'OTHERID',
                  'identifier': 'group.com.example.Other',
                  'name': 'Other',
                },
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

      final group = await client.findAppGroup('group.com.example.Shared');
      // The legacy protocol swaps the two names: the resource id arrives as
      // `applicationGroup` and the `group.…` string as `identifier`.
      expect(group?.id, 'GROUPID');
      expect(group?.identifier, 'group.com.example.Shared');
      client.close();
    });

    test('reports no group when the team has none matching', () async {
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient(
          (_) async => http.Response(
            PropertyListSerialization.stringWithPropertyList({
              'resultCode': 0,
              'applicationGroupList': <Object>[],
            }),
            200,
          ),
        ),
      );

      expect(await client.findAppGroup('group.com.example.Shared'), isNull);
      client.close();
    });

    test('registers a group with a punctuation-free name', () async {
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://developerservices2.apple.com/services/QH65B2/'
            'ios/addApplicationGroup.action?clientId=XABBG36SBA',
          );
          final body =
              PropertyListSerialization.propertyListWithString(request.body)
                  as Map;
          expect(body['identifier'], 'group.com.example.Shared');
          // Apple rejects punctuation in group names.
          expect(body['name'], 'xcross group com example Shared');
          return http.Response(
            PropertyListSerialization.stringWithPropertyList({
              'resultCode': 0,
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

      final group = await client.registerAppGroup(
        identifier: 'group.com.example.Shared',
        name: 'xcross group.com.example.Shared',
      );
      expect(group.id, 'NEWID');
      client.close();
    });

    test('enables the capability and links the groups', () async {
      final actions = <String>[];
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient((request) async {
          final action = request.url.pathSegments.last;
          actions.add(action);
          final body =
              PropertyListSerialization.propertyListWithString(request.body)
                  as Map;
          expect(body['appIdId'], 'APPID');
          if (action == 'updateAppId.action') {
            // Apple's internal feature key for App Groups.
            expect(body['APG3427HIY'], true);
          } else {
            expect(body['applicationGroups'], ['GROUPID']);
          }
          return http.Response(
            PropertyListSerialization.stringWithPropertyList({
              'resultCode': 0,
            }),
            200,
          );
        }),
      );

      await client.assignAppGroups(
        bundleIdResourceId: 'APPID',
        appGroupResourceIds: ['GROUPID'],
      );
      // Enabling the feature must come first: it is what makes Apple issue an
      // application-groups entitlement at all.
      expect(actions, [
        'updateAppId.action',
        'assignApplicationGroupToAppId.action',
      ]);
      client.close();
    });

    test('only enables the capability when no groups resolved', () async {
      final actions = <String>[];
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient((request) async {
          actions.add(request.url.pathSegments.last);
          return http.Response(
            PropertyListSerialization.stringWithPropertyList({
              'resultCode': 0,
            }),
            200,
          );
        }),
      );

      await client.assignAppGroups(
        bundleIdResourceId: 'APPID',
        appGroupResourceIds: const [],
      );
      expect(actions, ['updateAppId.action']);
      client.close();
    });

    test('surfaces a legacy resultCode failure', () async {
      final client = DeveloperServicesClient(
        token: _token(),
        teamId: 'TEAM',
        fetchAnisetteHeaders: () async => {},
        httpClient: MockClient(
          (_) async => http.Response(
            PropertyListSerialization.stringWithPropertyList({
              'resultCode': 9401,
              'userString': 'App Group unavailable',
            }),
            200,
          ),
        ),
      );

      await expectLater(
        client.registerAppGroup(
          identifier: 'group.com.example.Shared',
          name: 'Shared',
        ),
        throwsA(
          isA<AppleError>().having(
            (error) => error.toString(),
            'message',
            allOf(
              contains('addApplicationGroup.action'),
              contains('App Group unavailable'),
            ),
          ),
        ),
      );
      client.close();
    });
  });

  group('DeveloperServicesClient.listTeams', () {
    test('sends legacy plist request and parses teams', () async {
      var anisetteCalls = 0;
      final teams = await DeveloperServicesClient.listTeams(
        token: _token(),
        fetchAnisetteHeaders: () async {
          anisetteCalls++;
          return {'X-Apple-I-MD': 'fresh'};
        },
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://developerservices2.apple.com/services/QH65B2/'
            'listTeams.action?clientId=XABBG36SBA',
          );
          expect(
            request.headers['Content-Type'],
            startsWith('text/x-xml-plist'),
          );
          expect(request.headers['X-Xcode-Version'], '14.2 (14C18)');
          expect(request.headers['X-Apple-I-Identity-Id'], 'adsid');
          expect(request.headers['X-Apple-GS-Token'], 'token');
          expect(request.headers['X-Apple-I-MD'], 'fresh');
          final body =
              PropertyListSerialization.propertyListWithString(request.body)
                  as Map;
          expect(body['clientId'], 'XABBG36SBA');
          expect(body['protocolVersion'], 'QH65B2');
          expect(body['requestId'], isA<String>());
          expect(body['userLocale'], isA<List<Object?>>());
          return http.Response(
            PropertyListSerialization.stringWithPropertyList({
              'resultCode': '0',
              'teams': [
                {'teamId': 'T1', 'name': 'Personal Team', 'status': 'active'},
              ],
            }),
            200,
          );
        }),
      );

      expect(anisetteCalls, 1);
      expect(teams, hasLength(1));
      expect(teams.single.id, 'T1');
      expect(teams.single.name, 'Personal Team');
      expect(teams.single.status, 'active');
    });

    test('throws userString for nonzero legacy resultCode', () async {
      await expectLater(
        DeveloperServicesClient.listTeams(
          token: _token(),
          fetchAnisetteHeaders: () async => {},
          httpClient: MockClient(
            (_) async => http.Response(
              PropertyListSerialization.stringWithPropertyList({
                'resultCode': 35,
                'userString': 'Authentication failed',
              }),
              200,
            ),
          ),
        ),
        throwsA(
          isA<AppleError>().having(
            (error) => error.toString(),
            'message',
            contains('Authentication failed'),
          ),
        ),
      );
    });
  });
}

Map<String, Object?> _deviceJson(String udid) => {
  'id': 'device-$udid',
  'attributes': {'udid': udid, 'name': udid, 'status': 'ENABLED'},
};

DeveloperServicesLoginToken _token({bool expired = false}) =>
    DeveloperServicesLoginToken(
      adsid: 'adsid',
      token: 'token',
      expiry: DateTime.now().toUtc().add(Duration(days: expired ? -1 : 1)),
    );
