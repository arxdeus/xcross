import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/src/grandslam/app_token_exchange.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_login_data.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_response.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';

const _gsServiceUrl = 'https://gsa.apple.com/grandslam';

const _endpoints = GrandSlamEndpoints(
  gsService: _gsServiceUrl,
  secondaryAuth: 'secondaryAuth',
  trustedDeviceSecondaryAuth: 'https://gsa.apple.com/trusted',
  validateCode: 'https://gsa.apple.com/validate',
  midStartProvisioning: 'https://gsa.apple.com/start',
  midFinishProvisioning: 'https://gsa.apple.com/finish',
);

void main() {
  test('checksum matches xtool AppTokens.swift byte concatenation', () {
    final checksum = grandSlamAppTokenChecksum(
      sessionKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      adsid: '123456789',
      apps: const [kDeveloperServicesAppIdentifier],
    );

    expect(
      _hex(checksum),
      'c6a313d67f8df7fea65985a95141e23f1f55f3ad1687a8f7e92b81c5e6016c06',
    );
  });

  test('decryptGrandSlamAppTokenBlob opens the xtool AES-GCM blob layout', () {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final plaintext = Uint8List.fromList(utf8.encode('synthetic plist bytes'));
    final blob = _encryptBlob(key: key, plaintext: plaintext);

    expect(
      decryptGrandSlamAppTokenBlob(encryptedToken: blob, sessionKey: key),
      plaintext,
    );
  });

  test(
    'exchange posts o=apptokens and decodes the encrypted token plist',
    () async {
      final sessionKey = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final loginData = GrandSlamLoginData(
        adsid: '123456789',
        idmsToken: 'idms-token',
        sessionKey: sessionKey,
        cookie: Uint8List.fromList([1, 2, 3, 4]),
      );
      const expiryMs = 1893456000000; // 2030-01-01T00:00:00Z
      final tokenPlist = PropertyListSerialization.dataWithPropertyList({
        't': {
          kDeveloperServicesAppIdentifier: {
            'token': 'developer-services-token',
            'expiry': expiryMs,
          },
        },
      });
      final encryptedToken = _encryptBlob(
        key: sessionKey,
        plaintext: tokenPlist.buffer.asUint8List(
          tokenPlist.offsetInBytes,
          tokenPlist.lengthInBytes,
        ),
      );

      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), _gsServiceUrl);
        expect(request.headers['Content-Type'], startsWith('text/x-xml-plist'));
        expect(request.headers['Accept'], '*/*');
        expect(
          request.headers['User-Agent'],
          'akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0',
        );
        expect(request.headers['X-MMe-Client-Info'], 'fake-client-info');
        final envelope =
            PropertyListSerialization.propertyListWithString(request.body)
                as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        expect(req['o'], 'apptokens');
        expect(req['u'], loginData.adsid);
        expect(req['app'], [kDeveloperServicesAppIdentifier]);
        expect(_bytes(req['c']!), loginData.cookie);
        expect(req['t'], loginData.idmsToken);
        expect(
          _bytes(req['checksum']!),
          grandSlamAppTokenChecksum(
            sessionKey: sessionKey,
            adsid: loginData.adsid,
            apps: const [kDeveloperServicesAppIdentifier],
          ),
        );
        final cpd = (req['cpd']! as Map).cast<String, Object?>();
        expect(cpd['bootstrap'], isTrue);
        expect(cpd['X-Apple-I-MD'], 'otp');
        expect(cpd['X-Apple-I-MD-LU'], 'fake-lu-hash');
        expect(cpd['X-Apple-I-MD-M'], 'fake-mid');
        expect(cpd['X-Apple-I-MD-RINFO'], 84215040);
        expect(cpd['X-Apple-I-SRL-NO'], 'C02LKHBBFD57');
        expect(cpd['X-Mme-Device-Id'], 'fake-device-id');
        expect(cpd, isNot(contains('X-Apple-I-Locale')));
        expect(cpd, isNot(contains('X-MMe-Client-Info')));

        return http.Response(
          PropertyListSerialization.stringWithPropertyList({
            'Status': {'ec': 0, 'em': ''},
            'Response': {'et': byteDataOf(encryptedToken)},
          }),
          200,
        );
      });

      final exchange = GrandSlamAppTokenExchange(
        endpoints: _endpoints,
        fetchAnisetteHeaders: () async => const {
          'X-Apple-I-Client-Time': '2024-01-01T00:00:00Z',
          'X-Apple-I-MD': 'otp',
          'X-Apple-I-MD-LU': 'fake-lu-hash',
          'X-Apple-I-MD-M': 'fake-mid',
          'X-Apple-I-MD-RINFO': '84215040',
          'X-Apple-I-TimeZone': 'UTC',
          'X-Apple-Locale': 'en_US',
          'X-Mme-Device-Id': 'fake-device-id',
          'X-MMe-Client-Info': 'fake-client-info',
        },
        httpClient: client,
      );
      final token = await exchange.exchange(loginData);

      expect(token.adsid, loginData.adsid);
      expect(token.token, 'developer-services-token');
      expect(
        token.expiry,
        DateTime.fromMillisecondsSinceEpoch(expiryMs, isUtc: true),
      );
    },
  );
}

Uint8List _encryptBlob({required Uint8List key, required Uint8List plaintext}) {
  final aad = Uint8List.fromList(utf8.encode('XYZ'));
  final iv = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(true, pc.AEADParameters(pc.KeyParameter(key), 128, iv, aad));
  final sealed = cipher.process(plaintext); // ciphertext || tag
  return Uint8List.fromList([...aad, ...iv, ...sealed]);
}

Uint8List _bytes(Object value) {
  final data = value as ByteData;
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
