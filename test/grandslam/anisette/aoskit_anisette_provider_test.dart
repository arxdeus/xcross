import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/grandslam/anisette/aoskit_anisette_provider.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/process.dart';

const _clientInfo = '<native-client-info>';
const _deviceId = 'native-device-id';
const _localUserId = 'native-local-user-id';

void main() {
  group('AosKitHelper', () {
    test('parses the helper JSON document', () async {
      final helper = AosKitHelper(
        locateHelper: () async => 'helper.exe',
        runHelper: (_) async => CapturedProcess(
          0,
          '{"oneTimePassword":"otp","machineIdentifier":"machine",'
              '"routingInfo":"84215040","clientInfo":"$_clientInfo",'
              '"deviceId":"$_deviceId","localUserId":"$_localUserId"}',
          '',
        ),
      );

      final data = await helper.fetch();
      expect(data.oneTimePassword, 'otp');
      expect(data.machineIdentifier, 'machine');
      expect(data.routingInfo, '84215040');
      expect(data.clientInfo, _clientInfo);
      expect(data.deviceId, _deviceId);
      expect(data.localUserId, _localUserId);
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
    test(
      'keeps native identity headers verbatim with fresh helper data',
      () async {
        var fetches = 0;
        final provider = AosKitAnisetteProvider(
          fetchCoreData: () async {
            fetches++;
            return AosKitCoreData(
              oneTimePassword: 'otp-$fetches',
              machineIdentifier: 'machine-$fetches',
              routingInfo: '84215040',
              clientInfo: _clientInfo,
              deviceId: _deviceId,
              localUserId: _localUserId,
            );
          },
        );
        addTearDown(provider.close);

        final first = await provider.fetchAnisetteHeaders();
        final second = await provider.fetchAnisetteHeaders();

        expect(first['X-Apple-I-MD'], 'otp-1');
        expect(second['X-Apple-I-MD'], 'otp-2');
        expect(first['X-Apple-I-MD-M'], 'machine-1');
        expect(first['X-Apple-I-MD-RINFO'], '84215040');
        expect(first['X-Apple-I-MD-LU'], _localUserId);
        expect(first['X-Mme-Device-Id'], _deviceId);
        expect(first['X-MMe-Client-Info'], _clientInfo);
        expect(first['X-Apple-I-Client-Time'], matches(RegExp(r'Z$')));
        expect(fetches, 2);
      },
    );

    test(
      'resolves endpoints with the native device and client identity',
      () async {
        final provider = AosKitAnisetteProvider(
          fetchCoreData: () async => const AosKitCoreData(
            oneTimePassword: 'otp',
            machineIdentifier: 'machine',
            routingInfo: '84215040',
            clientInfo: _clientInfo,
            deviceId: _deviceId,
            localUserId: _localUserId,
          ),
          httpClient: MockClient((request) async {
            expect(request.method, 'GET');
            expect(request.headers['X-Mme-Device-Id'], _deviceId);
            expect(request.headers['X-MMe-Client-Info'], _clientInfo);
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
