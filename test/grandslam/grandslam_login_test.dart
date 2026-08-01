// Tests for [GrandSlamClient]: the `o=init`/`o=complete` SRP handshake and
// two-factor authentication (SMS + trusted-device).
//
// No real Apple servers are available (same constraint as every prior
// layer), so the HTTP layer is faked via `package:http/testing.dart`'s
// [MockClient] (matches `test/grandslam/anisette/anisette_data_provider_test.dart`'s
// pattern) and Anisette headers are faked via a plain injected callback
// (this task's equivalent of layer 2a's injectable `AdiProvisioning`).
//
// To make the "incorrect password" and 2FA-retry scenarios meaningful (not
// trivially-always-true), [_FakeGsaServer] below is a real, independent
// SRP-6a server-side implementation - deliberately re-derived from the
// protocol spec rather than copy-pasted from `srp_client.dart` or
// `srp_client_test.dart` - that the mocked HTTP handlers drive to produce
// genuinely-valid (or genuinely-invalid, for the failure tests) responses,
// including a real AES-256-CBC-encrypted `spd` and a real `negProto` HMAC.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:xcross/src/grandslam/grandslam_login.dart';

const _gsServiceUrl = 'https://gsa.apple.com/gsService';
const _trustedDeviceUrl = 'https://gsa.apple.com/trustedDeviceSecondaryAuth';
const _validateCodeUrl = 'https://gsa.apple.com/validateCode';
const _smsPutUrl = 'https://gsa.apple.com/auth/verify/phone/put?mode=sms';
const _smsValidateUrl =
    'https://gsa.apple.com/auth/verify/phone/securitycode'
    '?referrer=/auth/verify/phone/put';

const _testEndpoints = GrandSlamEndpoints(
  gsService: _gsServiceUrl,
  secondaryAuth: 'https://gsa.apple.com/secondaryAuth',
  trustedDeviceSecondaryAuth: _trustedDeviceUrl,
  validateCode: _validateCodeUrl,
  midStartProvisioning: 'https://gsa.apple.com/midStartProvisioning',
  midFinishProvisioning: 'https://gsa.apple.com/midFinishProvisioning',
);

Future<Map<String, String>> _fakeAnisetteHeaders() async => {
  'X-Apple-I-MD': 'fake-otp',
  'X-Apple-I-MD-M': 'fake-mid',
  'X-Apple-I-MD-RINFO': '84215040',
  'X-Apple-I-MD-LU': 'fake-lu-hash',
  'X-Mme-Device-Id': 'fake-device-id',
  'X-MMe-Client-Info': 'fake-client-info',
  'X-Apple-Locale': 'en_US',
  'X-Apple-I-TimeZone': 'UTC',
  'X-Apple-I-Client-Time': '2024-01-01T00:00:00Z',
};

void main() {
  group('successful login (no 2FA)', () {
    test('performs o=init -> o=complete and decodes the success payload', () async {
      const username = 'test@example.com';
      const password = 'hunter2';
      final server = _FakeGsaServer(username: username, password: password);

      http.Request? initRequest;
      http.Request? completeRequest;

      final client = MockClient((request) async {
        expect(request.url.toString(), _gsServiceUrl);
        expect(request.method, 'POST');
        expect(request.headers['Content-Type'], startsWith('text/x-xml-plist'));
        expect(request.headers['Accept'], '*/*');
        expect(
          request.headers['User-Agent'],
          'akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0',
        );
        expect(request.headers['X-MMe-Client-Info'], 'fake-client-info');

        final envelope =
            PropertyListSerialization.propertyListWithString(request.body) as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        final cpd = (req['cpd']! as Map).cast<String, Object?>();

        expect(cpd['bootstrap'], true);
        expect(cpd['icscrec'], true);
        expect(cpd['pbe'], false);
        expect(cpd['prkgen'], true);
        expect(cpd['svct'], 'iCloud');
        expect(cpd['loc'], 'en_US');
        expect(cpd['X-Apple-I-Client-Time'], '2024-01-01T00:00:00Z');
        expect(cpd['X-Apple-I-MD'], 'fake-otp');
        expect(cpd['X-Apple-I-MD-LU'], 'fake-lu-hash');
        expect(cpd['X-Apple-I-MD-M'], 'fake-mid');
        expect(cpd['X-Apple-I-MD-RINFO'], 84215040);
        expect(cpd['X-Apple-I-SRL-NO'], 'C02LKHBBFD57');
        expect(cpd['X-Apple-I-TimeZone'], 'UTC');
        expect(cpd['X-Apple-Locale'], 'en_US');
        expect(cpd['X-Mme-Device-Id'], 'fake-device-id');
        expect(cpd, isNot(contains('X-Apple-I-Locale')));
        expect(cpd, isNot(contains('X-MMe-Client-Info')));

        switch (req['o']) {
          case 'init':
            initRequest = request;
            expect(req['u'], username);
            expect(req['ps'], ['s2k', 's2k_fo']);
            final aBytes = _bytesOf(req['A2k']);
            server.receiveClientPublicKey(aBytes);
            return http.Response(
              _operationResponse({
                'sp': server.selectedProtocol,
                'c': 'cookie-abc',
                's': _bd(server.salt),
                'i': server.iterations,
                'B': _bd(server.serverPublicKeyBytes),
              }),
              200,
            );
          case 'complete':
            completeRequest = request;
            expect(req['c'], 'cookie-abc');
            final m1 = _bytesOf(req['M1']);
            final result = server.verifyAndRespond(m1);
            expect(result, isNotNull, reason: 'server should accept a correct password');
            final successPlist = PropertyListSerialization.stringWithPropertyList({
              'adsid': 'the-adsid',
              'GsIdmsToken': 'the-idms-token',
              'sk': _bd(result!.sessionKey),
              'c': _bd(Uint8List.fromList(utf8.encode('binary-cookie'))),
            });
            final spd = _encryptCbc(result.sessionKey, utf8.encode(successPlist));
            final negProto = _negProto(
              sessionKey: result.sessionKey,
              selectedProtocol: server.selectedProtocol,
              spd: spd,
            );
            return http.Response(
              _operationResponse({'M2': _bd(result.hamk), 'spd': _bd(spd), 'np': _bd(negProto)}),
              200,
            );
          default:
            throw StateError('unexpected o=${req['o']}');
        }
      });

      final grandSlam = GrandSlamClient(
        endpoints: _testEndpoints,
        fetchAnisetteHeaders: _fakeAnisetteHeaders,
        httpClient: client,
      );

      final loginData = await grandSlam.login(username: username, password: password);

      expect(loginData.adsid, 'the-adsid');
      expect(loginData.idmsToken, 'the-idms-token');
      expect(loginData.cookie, utf8.encode('binary-cookie'));
      expect(
        loginData.identityToken,
        base64Encode(utf8.encode('the-adsid:the-idms-token')),
      );
      expect(initRequest, isNotNull);
      expect(completeRequest, isNotNull);
    });

    test('lowercases the username before both the request and SRP', () async {
      const password = 'hunter2';
      final server = _FakeGsaServer(username: 'test@example.com', password: password);
      String? seenUsername;

      final client = MockClient((request) async {
        final envelope =
            PropertyListSerialization.propertyListWithString(request.body) as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        seenUsername = req['u'] as String?;
        if (req['o'] == 'init') {
          server.receiveClientPublicKey(_bytesOf(req['A2k']));
          return http.Response(
            _operationResponse({
              'sp': server.selectedProtocol,
              'c': 'cookie-abc',
              's': _bd(server.salt),
              'i': server.iterations,
              'B': _bd(server.serverPublicKeyBytes),
            }),
            200,
          );
        }
        final result = server.verifyAndRespond(_bytesOf(req['M1']))!;
        final successPlist = PropertyListSerialization.stringWithPropertyList({
          'adsid': 'a',
          'GsIdmsToken': 'b',
          'sk': _bd(result.sessionKey),
          'c': _bd(Uint8List.fromList([1, 2, 3])),
        });
        final spd = _encryptCbc(result.sessionKey, utf8.encode(successPlist));
        final negProto = _negProto(
          sessionKey: result.sessionKey,
          selectedProtocol: server.selectedProtocol,
          spd: spd,
        );
        return http.Response(
          _operationResponse({'M2': _bd(result.hamk), 'spd': _bd(spd), 'np': _bd(negProto)}),
          200,
        );
      });

      final grandSlam = GrandSlamClient(
        endpoints: _testEndpoints,
        fetchAnisetteHeaders: _fakeAnisetteHeaders,
        httpClient: client,
      );
      await grandSlam.login(username: 'TEST@Example.com', password: password);
      expect(seenUsername, 'test@example.com');
    });
  });

  group('incorrect password', () {
    test('throws GrandSlamAuthError when the server hamk does not verify', () async {
      const username = 'test@example.com';
      final server = _FakeGsaServer(username: username, password: 'correct-password');

      final client = MockClient((request) async {
        final envelope =
            PropertyListSerialization.propertyListWithString(request.body) as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        if (req['o'] == 'init') {
          server.receiveClientPublicKey(_bytesOf(req['A2k']));
          return http.Response(
            _operationResponse({
              'sp': server.selectedProtocol,
              'c': 'cookie-abc',
              's': _bd(server.salt),
              'i': server.iterations,
              'B': _bd(server.serverPublicKeyBytes),
            }),
            200,
          );
        }
        // Client used the wrong password, so its M1 won't match what the
        // server (registered with the correct password) expects.
        final result = server.verifyAndRespond(_bytesOf(req['M1']));
        expect(result, isNull, reason: 'server should reject a wrong-password M1');
        // A real GrandSlam server would presumably error out; simulate the
        // client-detectable consequence either way by returning a bogus
        // hamk/spd/np - `verifyServerProof` must catch this itself.
        final garbage = _randomBytes(32);
        return http.Response(
          _operationResponse({'M2': _bd(garbage), 'spd': _bd(garbage), 'np': _bd(garbage)}),
          200,
        );
      });

      final grandSlam = GrandSlamClient(
        endpoints: _testEndpoints,
        fetchAnisetteHeaders: _fakeAnisetteHeaders,
        httpClient: client,
      );

      await expectLater(
        () => grandSlam.login(username: username, password: 'wrong-password'),
        throwsA(isA<GrandSlamAuthError>()),
      );
    });
  });

  group('two-factor authentication', () {
    test('trusted-device push -> code validation -> full retry -> success', () async {
      const username = 'test@example.com';
      const password = 'hunter2';
      final server = _FakeGsaServer(username: username, password: password);

      var completeCallCount = 0;
      var pushSent = false;
      var validateCodeCalled = false;

      final client = MockClient((request) async {
        if (request.url.toString() == _trustedDeviceUrl) {
          expect(request.method, 'GET');
          expect(request.headers['X-Apple-Identity-Token'], isNotEmpty);
          expect(request.headers['X-Apple-App-Info'], 'com.apple.gs.xcode.auth');
          expect(request.headers['X-Xcode-Version'], isNotEmpty);
          pushSent = true;
          return http.Response('', 200);
        }
        if (request.url.toString() == _validateCodeUrl) {
          expect(request.method, 'GET');
          expect(request.headers['security-code'], '123456');
          validateCodeCalled = true;
          return http.Response('', 200);
        }
        expect(request.url.toString(), _gsServiceUrl);
        final envelope =
            PropertyListSerialization.propertyListWithString(request.body) as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        if (req['o'] == 'init') {
          server.receiveClientPublicKey(_bytesOf(req['A2k']));
          return http.Response(
            _operationResponse({
              'sp': server.selectedProtocol,
              'c': 'cookie-${completeCallCount + 1}',
              's': _bd(server.salt),
              'i': server.iterations,
              'B': _bd(server.serverPublicKeyBytes),
            }),
            200,
          );
        }
        completeCallCount++;
        final result = server.verifyAndRespond(_bytesOf(req['M1']))!;
        final needsTwoFactor = completeCallCount == 1;
        final plistMap = <String, Object?>{
          'adsid': 'the-adsid',
          'GsIdmsToken': 'the-idms-token',
          'sk': _bd(result.sessionKey),
          'c': _bd(Uint8List.fromList([9, 9, 9])),
          if (needsTwoFactor) 'status-code': 409,
          if (needsTwoFactor) 'url': 'trustedDeviceSecondaryAuth',
        };
        final successPlist = PropertyListSerialization.stringWithPropertyList(plistMap);
        final spd = _encryptCbc(result.sessionKey, utf8.encode(successPlist));
        final negProto = _negProto(
          sessionKey: result.sessionKey,
          selectedProtocol: server.selectedProtocol,
          spd: spd,
        );
        return http.Response(
          _operationResponse({'M2': _bd(result.hamk), 'spd': _bd(spd), 'np': _bd(negProto)}),
          200,
        );
      });

      GrandSlamTwoFactorMode? promptedMode;
      final grandSlam = GrandSlamClient(
        endpoints: _testEndpoints,
        fetchAnisetteHeaders: _fakeAnisetteHeaders,
        httpClient: client,
      );

      final loginData = await grandSlam.login(
        username: username,
        password: password,
        fetchTwoFactorCode: (mode) async {
          promptedMode = mode;
          return '123456';
        },
      );

      expect(promptedMode, GrandSlamTwoFactorMode.trustedDevice);
      expect(pushSent, isTrue);
      expect(validateCodeCalled, isTrue);
      expect(completeCallCount, 2, reason: 'must fully redo o=init/o=complete after 2FA');
      expect(loginData.adsid, 'the-adsid');
    });

    test('SMS 2FA: hits the hardcoded phone/put and securitycode endpoints', () async {
      const username = 'test@example.com';
      const password = 'hunter2';
      final server = _FakeGsaServer(username: username, password: password);

      var completeCallCount = 0;
      var smsSent = false;

      final client = MockClient((request) async {
        if (request.url.toString() == _smsPutUrl) {
          expect(request.method, 'POST');
          final body = PropertyListSerialization.propertyListWithString(request.body) as Map;
          final serverInfo = (body['serverInfo']! as Map).cast<String, Object?>();
          expect(serverInfo['phoneNumber.id'], '1');
          smsSent = true;
          return http.Response('', 200);
        }
        if (request.url.toString() == _smsValidateUrl) {
          expect(request.method, 'POST');
          final body = PropertyListSerialization.propertyListWithString(request.body) as Map;
          expect(body['securityCode.code'], '654321');
          final serverInfo = (body['serverInfo']! as Map).cast<String, Object?>();
          expect(serverInfo['mode'], 'sms');
          expect(serverInfo['phoneNumber.id'], '1');
          return http.Response('', 200);
        }
        final envelope =
            PropertyListSerialization.propertyListWithString(request.body) as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        if (req['o'] == 'init') {
          server.receiveClientPublicKey(_bytesOf(req['A2k']));
          return http.Response(
            _operationResponse({
              'sp': server.selectedProtocol,
              'c': 'cookie',
              's': _bd(server.salt),
              'i': server.iterations,
              'B': _bd(server.serverPublicKeyBytes),
            }),
            200,
          );
        }
        completeCallCount++;
        final result = server.verifyAndRespond(_bytesOf(req['M1']))!;
        final needsTwoFactor = completeCallCount == 1;
        final plistMap = <String, Object?>{
          'adsid': 'a',
          'GsIdmsToken': 'b',
          'sk': _bd(result.sessionKey),
          'c': _bd(Uint8List.fromList([1])),
          if (needsTwoFactor) 'status-code': 409,
          if (needsTwoFactor) 'url': 'secondaryAuth',
        };
        final successPlist = PropertyListSerialization.stringWithPropertyList(plistMap);
        final spd = _encryptCbc(result.sessionKey, utf8.encode(successPlist));
        final negProto = _negProto(
          sessionKey: result.sessionKey,
          selectedProtocol: server.selectedProtocol,
          spd: spd,
        );
        return http.Response(
          _operationResponse({'M2': _bd(result.hamk), 'spd': _bd(spd), 'np': _bd(negProto)}),
          200,
        );
      });

      GrandSlamTwoFactorMode? promptedMode;
      final grandSlam = GrandSlamClient(
        endpoints: _testEndpoints,
        fetchAnisetteHeaders: _fakeAnisetteHeaders,
        httpClient: client,
      );

      await grandSlam.login(
        username: username,
        password: password,
        fetchTwoFactorCode: (mode) async {
          promptedMode = mode;
          return '654321';
        },
      );

      expect(promptedMode, GrandSlamTwoFactorMode.sms);
      expect(smsSent, isTrue);
    });

    test('incorrect verification code (-21669) throws GrandSlamIncorrectCodeError', () async {
      const username = 'test@example.com';
      const password = 'hunter2';
      final server = _FakeGsaServer(username: username, password: password);

      final client = MockClient((request) async {
        if (request.url.toString() == _validateCodeUrl) {
          return http.Response(
            PropertyListSerialization.stringWithPropertyList({
              'Status': {'ec': -21669, 'em': 'Incorrect verification code.'},
              'Response': <String, Object?>{},
            }),
            200,
          );
        }
        final envelope =
            PropertyListSerialization.propertyListWithString(request.body) as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        if (req['o'] == 'init') {
          server.receiveClientPublicKey(_bytesOf(req['A2k']));
          return http.Response(
            _operationResponse({
              'sp': server.selectedProtocol,
              'c': 'cookie',
              's': _bd(server.salt),
              'i': server.iterations,
              'B': _bd(server.serverPublicKeyBytes),
            }),
            200,
          );
        }
        final result = server.verifyAndRespond(_bytesOf(req['M1']))!;
        final successPlist = PropertyListSerialization.stringWithPropertyList({
          'adsid': 'a',
          'GsIdmsToken': 'b',
          'sk': _bd(result.sessionKey),
          'c': _bd(Uint8List.fromList([1])),
          'status-code': 409,
          // url absent -> "unspecified" implicit 2FA path -> GET validateCode.
        });
        final spd = _encryptCbc(result.sessionKey, utf8.encode(successPlist));
        final negProto = _negProto(
          sessionKey: result.sessionKey,
          selectedProtocol: server.selectedProtocol,
          spd: spd,
        );
        return http.Response(
          _operationResponse({'M2': _bd(result.hamk), 'spd': _bd(spd), 'np': _bd(negProto)}),
          200,
        );
      });

      final grandSlam = GrandSlamClient(
        endpoints: _testEndpoints,
        fetchAnisetteHeaders: _fakeAnisetteHeaders,
        httpClient: client,
      );

      GrandSlamTwoFactorMode? promptedMode;
      await expectLater(
        () => grandSlam.login(
          username: username,
          password: password,
          fetchTwoFactorCode: (mode) async {
            promptedMode = mode;
            return '000000';
          },
        ),
        throwsA(isA<GrandSlamIncorrectCodeError>()),
      );
      expect(promptedMode, GrandSlamTwoFactorMode.unspecified);
    });

    test('throws GrandSlamTwoFactorRequiredError when no callback is provided', () async {
      const username = 'test@example.com';
      const password = 'hunter2';
      final server = _FakeGsaServer(username: username, password: password);

      final client = MockClient((request) async {
        final envelope =
            PropertyListSerialization.propertyListWithString(request.body) as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        if (req['o'] == 'init') {
          server.receiveClientPublicKey(_bytesOf(req['A2k']));
          return http.Response(
            _operationResponse({
              'sp': server.selectedProtocol,
              'c': 'cookie',
              's': _bd(server.salt),
              'i': server.iterations,
              'B': _bd(server.serverPublicKeyBytes),
            }),
            200,
          );
        }
        final result = server.verifyAndRespond(_bytesOf(req['M1']))!;
        final successPlist = PropertyListSerialization.stringWithPropertyList({
          'adsid': 'a',
          'GsIdmsToken': 'b',
          'sk': _bd(result.sessionKey),
          'c': _bd(Uint8List.fromList([1])),
          'status-code': 409,
        });
        final spd = _encryptCbc(result.sessionKey, utf8.encode(successPlist));
        final negProto = _negProto(
          sessionKey: result.sessionKey,
          selectedProtocol: server.selectedProtocol,
          spd: spd,
        );
        return http.Response(
          _operationResponse({'M2': _bd(result.hamk), 'spd': _bd(spd), 'np': _bd(negProto)}),
          200,
        );
      });

      final grandSlam = GrandSlamClient(
        endpoints: _testEndpoints,
        fetchAnisetteHeaders: _fakeAnisetteHeaders,
        httpClient: client,
      );

      await expectLater(
        () => grandSlam.login(username: username, password: password),
        throwsA(isA<GrandSlamTwoFactorRequiredError>()),
      );
    });

    test('throws GrandSlamAuthError if 2FA is still required after the retry', () async {
      const username = 'test@example.com';
      const password = 'hunter2';
      final server = _FakeGsaServer(username: username, password: password);

      final client = MockClient((request) async {
        if (request.url.toString() == _validateCodeUrl) {
          return http.Response('', 200);
        }
        final envelope =
            PropertyListSerialization.propertyListWithString(request.body) as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        if (req['o'] == 'init') {
          server.receiveClientPublicKey(_bytesOf(req['A2k']));
          return http.Response(
            _operationResponse({
              'sp': server.selectedProtocol,
              'c': 'cookie',
              's': _bd(server.salt),
              'i': server.iterations,
              'B': _bd(server.serverPublicKeyBytes),
            }),
            200,
          );
        }
        // Always report 2FA required, even on the retry.
        final result = server.verifyAndRespond(_bytesOf(req['M1']))!;
        final successPlist = PropertyListSerialization.stringWithPropertyList({
          'adsid': 'a',
          'GsIdmsToken': 'b',
          'sk': _bd(result.sessionKey),
          'c': _bd(Uint8List.fromList([1])),
          'status-code': 409,
        });
        final spd = _encryptCbc(result.sessionKey, utf8.encode(successPlist));
        final negProto = _negProto(
          sessionKey: result.sessionKey,
          selectedProtocol: server.selectedProtocol,
          spd: spd,
        );
        return http.Response(
          _operationResponse({'M2': _bd(result.hamk), 'spd': _bd(spd), 'np': _bd(negProto)}),
          200,
        );
      });

      final grandSlam = GrandSlamClient(
        endpoints: _testEndpoints,
        fetchAnisetteHeaders: _fakeAnisetteHeaders,
        httpClient: client,
      );

      await expectLater(
        () => grandSlam.login(
          username: username,
          password: password,
          fetchTwoFactorCode: (mode) async => '123456',
        ),
        throwsA(isA<GrandSlamAuthError>()),
      );
    });

    test('cancelling the code prompt throws GrandSlamTwoFactorCancelledError', () async {
      const username = 'test@example.com';
      const password = 'hunter2';
      final server = _FakeGsaServer(username: username, password: password);

      final client = MockClient((request) async {
        final envelope =
            PropertyListSerialization.propertyListWithString(request.body) as Map;
        final req = (envelope['Request']! as Map).cast<String, Object?>();
        if (req['o'] == 'init') {
          server.receiveClientPublicKey(_bytesOf(req['A2k']));
          return http.Response(
            _operationResponse({
              'sp': server.selectedProtocol,
              'c': 'cookie',
              's': _bd(server.salt),
              'i': server.iterations,
              'B': _bd(server.serverPublicKeyBytes),
            }),
            200,
          );
        }
        final result = server.verifyAndRespond(_bytesOf(req['M1']))!;
        final successPlist = PropertyListSerialization.stringWithPropertyList({
          'adsid': 'a',
          'GsIdmsToken': 'b',
          'sk': _bd(result.sessionKey),
          'c': _bd(Uint8List.fromList([1])),
          'status-code': 409,
        });
        final spd = _encryptCbc(result.sessionKey, utf8.encode(successPlist));
        final negProto = _negProto(
          sessionKey: result.sessionKey,
          selectedProtocol: server.selectedProtocol,
          spd: spd,
        );
        return http.Response(
          _operationResponse({'M2': _bd(result.hamk), 'spd': _bd(spd), 'np': _bd(negProto)}),
          200,
        );
      });

      final grandSlam = GrandSlamClient(
        endpoints: _testEndpoints,
        fetchAnisetteHeaders: _fakeAnisetteHeaders,
        httpClient: client,
      );

      await expectLater(
        () => grandSlam.login(
          username: username,
          password: password,
          fetchTwoFactorCode: (mode) async => null,
        ),
        throwsA(isA<GrandSlamTwoFactorCancelledError>()),
      );
    });
  });
}

// ---------------------------------------------------------------------
// Test-only plist helpers.
// ---------------------------------------------------------------------

String _operationResponse(Map<String, Object?> response) =>
    PropertyListSerialization.stringWithPropertyList({
      'Status': {'ec': 0, 'em': 'Success'},
      'Response': response,
    });

ByteData _bd(Uint8List bytes) => ByteData.sublistView(bytes);

Uint8List _bytesOf(Object? value) {
  final data = value! as ByteData;
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

// ---------------------------------------------------------------------
// Test-only, independent SRP-6a "server" + AES/HMAC helpers matching
// `srp_client.dart`'s protocol (RFC 5054 2048-bit group, SHA-256, Apple's
// custom `x`/proof framing) so the mocked HTTP handlers above can produce
// (or, for the wrong-password test, fail to produce) a genuinely-valid
// handshake. Deliberately independent plumbing from `srp_client.dart` and
// `srp_client_test.dart`'s own independent-server helpers (not shared/
// imported), matching this project's established test-independence style.
// ---------------------------------------------------------------------

final BigInt _n = BigInt.parse(
  'AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC31929'
  '43DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D'
  'CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB'
  'D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74'
  '7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A'
  '436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D'
  '5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73'
  '03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6'
  '94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F'
  '9E4AFF73',
  radix: 16,
);
final BigInt _g = BigInt.two;
final int _nByteLength = (_n.bitLength + 7) ~/ 8;

class _SrpVerifyResult {
  _SrpVerifyResult({required this.hamk, required this.sessionKey});
  final Uint8List hamk;
  final Uint8List sessionKey;
}

/// A minimal independent SRP-6a "server": registers a password (computing
/// its verifier `v`), accepts the client's public key `A`, generates its
/// own ephemeral `b`/`B`, and can verify a client-submitted `M1` against
/// its own independently-derived expectation.
class _FakeGsaServer {
  _FakeGsaServer({required this.username, required this.password})
    : salt = _randomBytes(16);

  final String username;
  final String password;
  final Uint8List salt;

  // Only the modern 's2k' protocol / a fixed iteration count are
  // exercised here; 's2k_fo' and variable iteration counts are already
  // covered independently by srp_client_test.dart's self-consistency
  // tests, so this fake server doesn't need to vary them too.
  static const bool legacyProtocol = false;
  static const int _iterations = 1000;
  int get iterations => _iterations;

  String get selectedProtocol => legacyProtocol ? 's2k_fo' : 's2k';

  late BigInt _bigA;
  late BigInt _bigB;
  late BigInt _v;
  late BigInt _b;

  void receiveClientPublicKey(Uint8List aBytes) {
    _bigA = _bytesToBigInt(aBytes);
    final x = _computeX(
      password: password,
      salt: salt,
      iterations: iterations,
      legacy: legacyProtocol,
    );
    _v = _g.modPow(x, _n);
    _b = _bytesToBigInt(_randomBytes(32));
    final k = _calcXY(_n, _g);
    _bigB = (k * _v + _g.modPow(_b, _n)) % _n;
  }

  Uint8List get serverPublicKeyBytes => _bigIntToBytes(_bigB);

  /// Verifies the client's `M1`; if it matches this server's own
  /// independently-computed expectation, returns the resulting `hamk`
  /// (`M2`) and session key `K`. Returns `null` on mismatch (e.g. the
  /// client used the wrong password, so its `K` - and thus `M` - differs).
  _SrpVerifyResult? verifyAndRespond(Uint8List m1) {
    final u = _calcXY(_bigA, _bigB);
    final s = (_bigA * _v.modPow(u, _n) % _n).modPow(_b, _n);
    final k = Uint8List.fromList(crypto.sha256.convert(_bigIntToBytes(s)).bytes);

    final aBytes = _bigIntToBytes(_bigA);
    final bBytes = serverPublicKeyBytes;
    final gHash = crypto.sha256.convert(_padLeft(_bigIntToBytes(_g), _nByteLength)).bytes;
    final nHash = crypto.sha256.convert(_bigIntToBytes(_n)).bytes;
    final xorHash = List<int>.generate(gHash.length, (i) => gHash[i] ^ nHash[i]);
    final hi = crypto.sha256.convert(utf8.encode(username)).bytes;
    final expectedM = Uint8List.fromList(
      crypto.sha256.convert([...xorHash, ...hi, ...salt, ...aBytes, ...bBytes, ...k]).bytes,
    );
    if (!_constantTimeEquals(expectedM, m1)) return null;

    final hamk = Uint8List.fromList(
      crypto.sha256.convert([...aBytes, ...m1, ...k]).bytes,
    );
    return _SrpVerifyResult(hamk: hamk, sessionKey: k);
  }
}

BigInt _computeX({
  required String password,
  required Uint8List salt,
  required int iterations,
  required bool legacy,
}) {
  final hashedPassword = Uint8List.fromList(crypto.sha256.convert(utf8.encode(password)).bytes);
  final Uint8List pbkdfInput;
  if (legacy) {
    pbkdfInput = Uint8List.fromList(
      utf8.encode(hashedPassword.map((b) => b.toRadixString(16).padLeft(2, '0')).join()),
    );
  } else {
    pbkdfInput = hashedPassword;
  }
  final derivator = pc.PBKDF2KeyDerivator(pc.HMac.withDigest(pc.SHA256Digest()))
    ..init(pc.Pbkdf2Parameters(salt, iterations, 32));
  final passkey = derivator.process(pbkdfInput);
  final inner = crypto.sha256.convert([0x3a, ...passkey]).bytes;
  final x = crypto.sha256.convert([...salt, ...inner]).bytes;
  return _bytesToBigInt(x);
}

BigInt _calcXY(BigInt x, BigInt y) {
  final padX = _padLeft(_bigIntToBytes(x), _nByteLength);
  final padY = _padLeft(_bigIntToBytes(y), _nByteLength);
  return _bytesToBigInt(crypto.sha256.convert([...padX, ...padY]).bytes);
}

Uint8List _padLeft(Uint8List bytes, int length) {
  if (bytes.length >= length) return bytes;
  final padded = Uint8List(length);
  padded.setRange(length - bytes.length, length, bytes);
  return padded;
}

Uint8List _bigIntToBytes(BigInt value) {
  if (value == BigInt.zero) return Uint8List.fromList([0]);
  final bytes = <int>[];
  var n = value;
  final mask = BigInt.from(0xff);
  while (n > BigInt.zero) {
    bytes.insert(0, (n & mask).toInt());
    n = n >> 8;
  }
  return Uint8List.fromList(bytes);
}

BigInt _bytesToBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) + BigInt.from(b);
  }
  return result;
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List _hmacSha256(Uint8List key, List<int> message) =>
    Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(message).bytes);

Uint8List _sessionSubkey(Uint8List sessionKey, String name) =>
    _hmacSha256(sessionKey, utf8.encode(name));

/// AES-256-CBC/PKCS7 encrypt, matching `SrpClient.decryptCbc`'s key/IV
/// derivation (`HMAC-SHA256(K, "extra data key:"/"extra data iv:")`).
Uint8List _encryptCbc(Uint8List sessionKey, Uint8List plaintext) {
  final aesKey = _sessionSubkey(sessionKey, 'extra data key:');
  final iv = _sessionSubkey(sessionKey, 'extra data iv:').sublist(0, 16);
  final cipher = pc.PaddedBlockCipherImpl(pc.PKCS7Padding(), pc.CBCBlockCipher(pc.AESEngine()))
    ..init(true, pc.PaddedBlockCipherParameters(pc.ParametersWithIV(pc.KeyParameter(aesKey), iv), null));
  return cipher.process(plaintext);
}

/// Builds the same negotiated-protocol digest `SrpClient.addString`/
/// `addData` sequencing `GrandSlamClient` uses (see its doc comment), and
/// HMACs it exactly like `SrpClient.verifyNegotiatedProtocols` does, so
/// that check exercises real, matching bytes rather than being trivially
/// skipped/always-true in these tests.
Uint8List _negProto({
  required Uint8List sessionKey,
  required String selectedProtocol,
  required Uint8List spd,
  Uint8List? sc,
}) {
  final digest = BytesBuilder();
  void addString(String s) => digest.add(utf8.encode(s));
  void addData(Uint8List d) {
    final len = ByteData(4)..setUint32(0, d.length, Endian.little);
    digest.add(len.buffer.asUint8List());
    digest.add(d);
  }

  addString('s2k,s2k_fo');
  addString('|');
  addString('|');
  addString(selectedProtocol);
  addString('|');
  addData(spd);
  addString('|');
  if (sc != null) addData(sc);
  addString('|');

  final hash = crypto.sha256.convert(digest.toBytes()).bytes;
  final hmacKey = _sessionSubkey(sessionKey, 'HMAC key:');
  return _hmacSha256(hmacKey, hash);
}
