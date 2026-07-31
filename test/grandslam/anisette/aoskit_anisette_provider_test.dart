import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/grandslam/anisette/anisette_headers.dart';
import 'package:xcross/src/grandslam/anisette/anisette_state.dart';
import 'package:xcross/src/grandslam/anisette/aoskit_anisette_provider.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/process.dart';

const _uid = '12345678-1234-4234-8234-123456789abc';

void main() {
  group('AosKitHelper', () {
    test('parses the helper JSON document', () async {
      final helper = AosKitHelper(
        locateHelper: () async => 'helper.exe',
        runHelper: (_) async => CapturedProcess(
          0,
          '{"oneTimePassword":"otp","machineIdentifier":"machine",'
              '"routingInfo":"17106176"}',
          '',
        ),
      );

      final data = await helper.fetch();
      expect(data.oneTimePassword, 'otp');
      expect(data.machineIdentifier, 'machine');
      expect(data.routingInfo, '17106176');
    });

    test('does not echo secret material from malformed helper JSON', () async {
      final helper = AosKitHelper(
        locateHelper: () async => 'helper.exe',
        runHelper: (_) async =>
            CapturedProcess(0, '{"oneTimePassword":"secret-otp",BROKEN', ''),
      );

      await expectLater(
        helper.fetch(),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('secret-otp')),
          ),
        ),
      );
    });

    test('surfaces a nonzero helper diagnostic', () async {
      final helper = AosKitHelper(
        locateHelper: () async => 'helper.exe',
        runHelper: (_) async =>
            CapturedProcess(6, 'secret-otp', 'AOSKit unavailable'),
      );

      await expectLater(
        helper.fetch(),
        throwsA(
          isA<XcrossError>()
              .having(
                (error) => error.toString(),
                'message',
                contains('AOSKit unavailable'),
              )
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains('secret-otp')),
              ),
        ),
      );
    });
  });

  group('AosKitAnisetteProvider', () {
    late Directory temp;
    late AnisetteStateStore stateStore;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('xcross_aoskit_provider');
      stateStore = AnisetteStateStore(path: p.join(temp.path, 'state.json'));
      await stateStore.save(const AnisetteState(localUserUid: _uid));
    });

    tearDown(() => temp.deleteSync(recursive: true));

    test('builds the complete header set with fresh helper data', () async {
      var fetches = 0;
      final provider = AosKitAnisetteProvider(
        stateStore: stateStore,
        fetchCoreData: () async {
          fetches++;
          return AosKitCoreData(
            oneTimePassword: 'otp-$fetches',
            machineIdentifier: 'machine-$fetches',
            routingInfo: '17106176',
          );
        },
      );
      addTearDown(provider.close);

      final first = await provider.fetchAnisetteHeaders();
      final second = await provider.fetchAnisetteHeaders();

      expect(first['X-Apple-I-MD'], 'otp-1');
      expect(second['X-Apple-I-MD'], 'otp-2');
      expect(first['X-Apple-I-MD-M'], 'machine-1');
      expect(first['X-Apple-I-MD-RINFO'], '17106176');
      expect(first['X-Apple-I-MD-LU'], anisetteLocalUserIdHash(_uid));
      expect(first['X-Mme-Device-Id'], _uid);
      expect(first['X-MMe-Client-Info'], anisetteClientInfo);
      expect(first['X-Apple-I-Client-Time'], matches(RegExp(r'Z$')));
      expect(fetches, 2);
    });

    test(
      'resolves endpoints with the persisted pseudo-device identity',
      () async {
        final provider = AosKitAnisetteProvider(
          stateStore: stateStore,
          fetchCoreData: () async => const AosKitCoreData(
            oneTimePassword: 'otp',
            machineIdentifier: 'machine',
            routingInfo: '17106176',
          ),
          httpClient: MockClient((request) async {
            expect(request.method, 'GET');
            expect(request.headers['X-Mme-Device-Id'], _uid);
            return http.Response(
              PropertyListSerialization.stringWithPropertyList({
                'urls': {
                  'gsService': 'https://gsa.apple.com/gs',
                  'secondaryAuth': 'https://gsa.apple.com/secondary',
                  'trustedDeviceSecondaryAuth': 'https://gsa.apple.com/trusted',
                  'validateCode': 'https://gsa.apple.com/validate',
                  'midStartProvisioning': 'https://gsa.apple.com/start',
                  'midFinishProvisioning': 'https://gsa.apple.com/finish',
                },
              }),
              200,
            );
          }),
        );
        addTearDown(provider.close);

        expect(
          (await provider.resolveGrandSlamEndpoints()).gsService,
          'https://gsa.apple.com/gs',
        );
      },
    );
  });
}
