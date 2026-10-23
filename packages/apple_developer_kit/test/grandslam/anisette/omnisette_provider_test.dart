// Tests for [OmnisetteAnisetteProvider]: the v3 Omnisette wire protocol
// (client_info, provisioning WebSocket dialog, get_headers), persisted-state
// gating, and provider-switch invalidation. HTTP is faked with
// `package:http/testing.dart`; the WebSocket is faked with a scripted
// [OmnisetteSocket].
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/omnisette_provider.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';

import '../../support/host_services.dart';

const _baseUrl = 'https://omnisette.test';
const _lookupUrl = 'https://gsa.apple.com/grandslam/GsService2/lookup';
const _midStartUrl = 'https://gsa.apple.com/gsa/midStartProvisioning';
const _midFinishUrl = 'https://gsa.apple.com/gsa/midFinishProvisioning';
const _uuid = '00112233-4455-4677-8899-aabbccddeeff';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

String _b64(String s) => base64Encode(_bytes(s));

String _lookupResponsePlist() =>
    PropertyListSerialization.stringWithPropertyList({
      'urls': {
        'gsService': 'https://gsa.apple.com/gsa/gsService',
        'secondaryAuth': 'https://gsa.apple.com/gsa/secondaryAuth',
        'trustedDeviceSecondaryAuth':
            'https://gsa.apple.com/gsa/trustedDeviceSecondaryAuth',
        'validateCode': 'https://gsa.apple.com/gsa/validateCode',
        'midStartProvisioning': _midStartUrl,
        'midFinishProvisioning': _midFinishUrl,
      },
    });

String _gsaResponsePlist(Map<String, Object?> response) =>
    PropertyListSerialization.stringWithPropertyList({
      'Status': {'ec': 0, 'em': 'Success'},
      'Response': response,
    });

const _macClientInfo =
    '<MacBookPro18,3> <macOS; 15.4; 24E248> <com.apple.AuthKit/1 '
    '(com.apple.akd/1.0)>';

@internal
final class FakeOmnisetteSocket implements OmnisetteSocket {
  FakeOmnisetteSocket(this.incoming);

  final List<String> incoming;
  final List<String> sent = <String>[];
  bool closed = false;

  @override
  Future<void> send(String message) async {
    sent.add(message);
  }

  @override
  Future<String> receive() async => incoming.removeAt(0);

  @override
  void close() {
    closed = true;
  }
}

void main() {
  late Directory tempDir;
  late String statePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xcross_omnisette');
    statePath = '${tempDir.path}${Platform.pathSeparator}anisette-state.json';
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  AnisetteStateStore stateStore() =>
      AnisetteStateStore(hostServices: testHostServices, path: statePath);

  OmnisetteAnisetteProvider provider(
    http.Client client, {
    OmnisetteSocketConnector? connector,
    AnisetteStateStore? store,
  }) => OmnisetteAnisetteProvider(
    hostServices: testHostServices,
    httpClient: client,
    stateStore: store ?? stateStore(),
    baseUrl: _baseUrl,
    connector: connector,
  );

  MockClient otpClient({Map<String, Object>? getHeadersResponse}) {
    return MockClient((request) async {
      switch (request.url.toString()) {
        case _lookupUrl:
          return http.Response(_lookupResponsePlist(), 200);
        case _midStartUrl:
          return http.Response(
            _gsaResponsePlist({'spim': _b64('server-spim')}),
            200,
          );
        case _midFinishUrl:
          return http.Response(
            _gsaResponsePlist({
              'ptm': _b64('ptm-bytes'),
              'tk': _b64('tk-bytes'),
              'X-Apple-I-MD-RINFO': '1717976940',
            }),
            200,
          );
        case '$_baseUrl/v3/client_info':
          return http.Response('{"client_info": "$_macClientInfo"}', 200);
        case '$_baseUrl/v3/get_headers':
          return http.Response(
            jsonEncode(
              getHeadersResponse ??
                  {
                    'X-Apple-I-MD-M': _b64('machine-id'),
                    'X-Apple-I-MD': _b64('otp'),
                    'X-Apple-I-MD-RINFO': '1717976940',
                  },
            ),
            200,
          );
        default:
          return http.Response('unexpected: ${request.url}', 500);
      }
    });
  }

  Future<AnisetteState> provisionedState() async {
    final state = AnisetteState(
      localUserUid: _uuid,
      provisioned: true,
      routingInfo: 1717976940,
      adiPb: _b64('adi.pb-bytes'),
      providerId: kOmnisetteProviderId,
    );
    await stateStore().save(state);
    return state;
  }

  test('fetchAnisetteHeaders posts adi.pb and builds Mac headers', () async {
    await provisionedState();
    http.Request? otpRequest;
    final client = MockClient((request) async {
      if (request.url.toString() == '$_baseUrl/v3/get_headers') {
        otpRequest = request;
        return http.Response(
          jsonEncode({
            'X-Apple-I-MD-M': _b64('machine-id'),
            'X-Apple-I-MD': _b64('otp'),
            'X-Apple-I-MD-RINFO': '1717976940',
          }),
          200,
        );
      }
      if (request.url.toString() == '$_baseUrl/v3/client_info') {
        return http.Response('{"client_info": "$_macClientInfo"}', 200);
      }
      return http.Response('unexpected: ${request.url}', 500);
    });

    final headers = await provider(client).fetchAnisetteHeaders();

    final body = jsonDecode(otpRequest!.body) as Map<String, Object?>;
    expect(body['adi_pb'], _b64('adi.pb-bytes'));
    expect(
      base64Decode(body['identifier']! as String),
      Uint8List.fromList([
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x46, 0x77, //
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
      ]),
    );
    expect(headers['X-Apple-I-MD'], _b64('otp'));
    expect(headers['X-Apple-I-MD-M'], _b64('machine-id'));
    expect(headers['X-Apple-I-MD-RINFO'], '1717976940');
    expect(headers['X-MMe-Client-Info'], _macClientInfo);
    expect(headers['X-Mme-Device-Id'], _uuid);
    expect(
      headers['X-Apple-I-MD-LU'],
      crypto.sha256.convert(utf8.encode(_uuid)).toString().toUpperCase(),
    );
  });

  test('full provisioning handshake drives the socket dialog', () async {
    await stateStore().save(
      const AnisetteState(
        localUserUid: _uuid,
        providerId: kOmnisetteProviderId,
      ),
    );
    final client = MockClient((request) async {
      switch (request.url.toString()) {
        case _lookupUrl:
          return http.Response(_lookupResponsePlist(), 200);
        case _midStartUrl:
          return http.Response(
            _gsaResponsePlist({'spim': _b64('server-spim')}),
            200,
          );
        case _midFinishUrl:
          return http.Response(
            _gsaResponsePlist({
              'ptm': _b64('ptm-bytes'),
              'tk': _b64('tk-bytes'),
              'X-Apple-I-MD-RINFO': '1717976940',
            }),
            200,
          );
        case '$_baseUrl/v3/client_info':
          return http.Response('{"client_info": "$_macClientInfo"}', 200);
        case '$_baseUrl/v3/get_headers':
          return http.Response(
            jsonEncode({
              'X-Apple-I-MD-M': _b64('machine-id'),
              'X-Apple-I-MD': _b64('otp'),
              'X-Apple-I-MD-RINFO': '1717976940',
            }),
            200,
          );
        default:
          return http.Response('unexpected: ${request.url}', 500);
      }
    });

    FakeOmnisetteSocket? socket;
    Uri? socketUri;
    final p = provider(
      client,
      connector: (uri) async {
        socketUri = uri;
        return socket = FakeOmnisetteSocket([
          jsonEncode({'result': 'GiveIdentifier'}),
          jsonEncode({'result': 'GiveStartProvisioningData'}),
          jsonEncode({
            'result': 'GiveEndProvisioningData',
            'cpim': _b64('cpim-bytes'),
          }),
          jsonEncode({
            'result': 'ProvisioningSuccess',
            'adi_pb': _b64('adi.pb-bytes'),
          }),
        ]);
      },
    );

    final headers = await p.fetchAnisetteHeaders();

    expect(
      socketUri.toString(),
      'wss://omnisette.test/v3/provisioning_session',
    );
    expect(socket!.closed, isTrue);
    expect(
      socket!.sent.map(jsonDecode).toList(),
      [
        {'identifier': 'ABEiM0RVRneImaq7zN3u/w=='},
        // 00112233-4455-4677-8899-aabbccddeeff as raw bytes.
        {'spim': _b64('server-spim')},
        {'ptm': _b64('ptm-bytes'), 'tk': _b64('tk-bytes')},
      ],
    );
    expect(headers['X-Apple-I-MD'], _b64('otp'));

    final saved = await stateStore().load();
    expect(saved.provisioned, isTrue);
    expect(saved.routingInfo, 1717976940);
    expect(saved.adiPb, _b64('adi.pb-bytes'));
    expect(saved.providerId, kOmnisetteProviderId);
  });

  test('stored state from another provider is reset and reprovisioned',
      () async {
    await stateStore().save(
      const AnisetteState(
        localUserUid: _uuid,
        provisioned: true,
        routingInfo: 1,
        providerId: 'android-adi',
      ),
    );
    var sockets = 0;
    final p = provider(
      otpClient(),
      connector: (uri) async {
        sockets++;
        return FakeOmnisetteSocket([
          jsonEncode({'result': 'GiveIdentifier'}),
          jsonEncode({'result': 'GiveStartProvisioningData'}),
          jsonEncode({
            'result': 'GiveEndProvisioningData',
            'cpim': _b64('cpim-bytes'),
          }),
          jsonEncode({
            'result': 'ProvisioningSuccess',
            'adi_pb': _b64('adi.pb-bytes'),
          }),
        ]);
      },
    );

    final headers = await p.fetchAnisetteHeaders();

    expect(sockets, 1);
    expect(headers['X-Apple-I-MD'], isNotNull);
    final saved = await stateStore().load();
    expect(saved.providerId, kOmnisetteProviderId);
    expect(saved.routingInfo, 1717976940);
  });

  test('client_info is fetched once and reused for the lookup', () async {
    await provisionedState();
    var clientInfos = 0;
    final client = MockClient((request) async {
      switch (request.url.toString()) {
        case _lookupUrl:
          return http.Response(_lookupResponsePlist(), 200);
        case '$_baseUrl/v3/client_info':
          clientInfos++;
          return http.Response('{"client_info": "$_macClientInfo"}', 200);
        case '$_baseUrl/v3/get_headers':
          return http.Response(
            jsonEncode({
              'X-Apple-I-MD-M': _b64('machine-id'),
              'X-Apple-I-MD': _b64('otp'),
              'X-Apple-I-MD-RINFO': '1717976940',
            }),
            200,
          );
        default:
          return http.Response('unexpected: ${request.url}', 500);
      }
    });

    final p = provider(client);
    final endpoints = await p.resolveGrandSlamEndpoints();
    await p.fetchAnisetteHeaders();

    expect(endpoints.midStartProvisioning, _midStartUrl);
    expect(clientInfos, 1);
  });

  test('unexpected socket message fails the handshake', () async {
    final socket = FakeOmnisetteSocket([
      jsonEncode({'result': 'NotGiveIdentifier'}),
    ]);
    final p = provider(
      otpClient(),
      connector: (uri) async => socket,
    );

    await expectLater(
      p.fetchAnisetteHeaders(),
      throwsA(
        isA<AppleError>().having(
          (error) => error.message,
          'message',
          contains('Expected Omnisette message "GiveIdentifier"'),
        ),
      ),
    );
  });

  test('get_headers failure surfaces as an AppleError', () async {
    await provisionedState();
    final client = MockClient((request) async {
      if (request.url.toString() == '$_baseUrl/v3/client_info') {
        return http.Response('{"client_info": "$_macClientInfo"}', 200);
      }
      if (request.url.toString() == '$_baseUrl/v3/get_headers') {
        return http.Response('server error', 500);
      }
      return http.Response('unexpected: ${request.url}', 500);
    });

    await expectLater(
      provider(client).fetchAnisetteHeaders(),
      throwsA(isA<AppleError>()),
    );
  });
}
