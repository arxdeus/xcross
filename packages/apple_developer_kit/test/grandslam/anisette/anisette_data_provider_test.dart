// Tests for [AnisetteDataProvider]: header-assembly formatting, the
// one-time provisioning handshake's plist request/response shapes, and
// persisted-state gating (skip provisioning once already done). Real
// network calls and the real (Linux-only) native ADI library are both
// unavailable in this environment, so both are faked: the HTTP layer via
// `package:http/testing.dart`'s [MockClient] (an existing dependency, not
// a new one), and ADI via a hand-written [AdiProvisioning] fake.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/grandslam/anisette/anisette_data_provider.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';

const _lookupUrl = 'https://gsa.apple.com/grandslam/GsService2/lookup';
const _midStartUrl = 'https://gsa.apple.com/gsa/midStartProvisioning';
const _midFinishUrl = 'https://gsa.apple.com/gsa/midFinishProvisioning';

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

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// A fake [AdiProvisioning] driving canned provisioning-handshake data,
/// matching the shapes `AdiClient` (`package:provision_dart`) returns.
class FakeAdiProvisioning implements AdiProvisioning {
  FakeAdiProvisioning({this.alreadyProvisioned = false});

  final bool alreadyProvisioned;

  bool startProvisioningCalled = false;
  bool endProvisioningCalled = false;
  int otpCallCount = 0;
  Uint8List? seenSpim;
  int? seenEndSession;
  Uint8List? seenPtm;
  Uint8List? seenTk;

  @override
  Future<bool> isMachineProvisioned(int dsId) async {
    expect(dsId, kAdiMachineDsId);
    return alreadyProvisioned;
  }

  @override
  Future<AdiClientProvisioningIntermediateMetadata> startProvisioning(
    int dsId,
    Uint8List serverProvisioningIntermediateMetadata,
  ) async {
    expect(dsId, kAdiMachineDsId);
    startProvisioningCalled = true;
    seenSpim = serverProvisioningIntermediateMetadata;
    return AdiClientProvisioningIntermediateMetadata(
      clientProvisioningIntermediateMetadata: _bytes('fake-cpim'),
      session: 42,
    );
  }

  @override
  Future<void> endProvisioning(
    int session,
    Uint8List persistentTokenMetadata,
    Uint8List trustKey,
  ) async {
    endProvisioningCalled = true;
    seenEndSession = session;
    seenPtm = persistentTokenMetadata;
    seenTk = trustKey;
  }

  @override
  Future<AdiOneTimePassword> requestOTP(int dsId) async {
    expect(dsId, kAdiMachineDsId);
    otpCallCount++;
    return AdiOneTimePassword(
      oneTimePassword: _bytes('otp-$otpCallCount'),
      machineIdentifier: _bytes('mid-$otpCallCount'),
    );
  }
}

class _RefusingAdiProvisioning implements AdiProvisioning {
  @override
  Future<bool> isMachineProvisioned(int dsId) =>
      throw StateError('unexpected ADI call: isMachineProvisioned');

  @override
  Future<AdiClientProvisioningIntermediateMetadata> startProvisioning(
    int dsId,
    Uint8List serverProvisioningIntermediateMetadata,
  ) => throw StateError('unexpected ADI call: startProvisioning');

  @override
  Future<void> endProvisioning(
    int session,
    Uint8List persistentTokenMetadata,
    Uint8List trustKey,
  ) => throw StateError('unexpected ADI call: endProvisioning');

  @override
  Future<AdiOneTimePassword> requestOTP(int dsId) async {
    expect(dsId, kAdiMachineDsId);
    return AdiOneTimePassword(
      oneTimePassword: _bytes('cached-otp'),
      machineIdentifier: _bytes('cached-mid'),
    );
  }
}

void main() {
  late Directory tempDir;
  late String statePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'xcross_anisette_provider_test',
    );
    statePath = p.join(tempDir.path, 'anisette-state.json');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test(
    'runs the provisioning handshake, persists state, and assembles headers',
    () async {
      const localUserUid = '11111111-2222-4333-8444-555555555555';
      await AnisetteStateStore(
        path: statePath,
      ).save(const AnisetteState(localUserUid: localUserUid));

      final fake = FakeAdiProvisioning();
      http.Request? startRequest;
      http.Request? finishRequest;

      final client = MockClient((request) async {
        switch (request.url.toString()) {
          case _lookupUrl:
            return http.Response(_lookupResponsePlist(), 200);
          case _midStartUrl:
            startRequest = request;
            return http.Response(
              _gsaResponsePlist({'spim': base64Encode(_bytes('server-spim'))}),
              200,
            );
          case _midFinishUrl:
            finishRequest = request;
            return http.Response(
              _gsaResponsePlist({
                'ptm': base64Encode(_bytes('server-ptm')),
                'tk': base64Encode(_bytes('server-tk')),
                'X-Apple-I-MD-RINFO': '1234567890123',
              }),
              200,
            );
          default:
            throw StateError('unexpected request to ${request.url}');
        }
      });

      final provider = AnisetteDataProvider(
        '/fake/adi/lib/dir',
        httpClient: client,
        stateStore: AnisetteStateStore(path: statePath),
        adiFactory:
            ({
              required adiLibraryDirectory,
              required provisioningPath,
              required identifier,
            }) {
              expect(adiLibraryDirectory, '/fake/adi/lib/dir');
              // Matches xtool's XADIProvider: first 16 lowercase hex chars of
              // the UUID with dashes stripped.
              expect(identifier, '1111111122224333');
              return fake;
            },
      );

      final headers = await provider.fetchAnisetteHeaders();

      // --- provisioning handshake ran exactly once, in order ---
      expect(fake.startProvisioningCalled, isTrue);
      expect(fake.endProvisioningCalled, isTrue);
      expect(fake.seenSpim, _bytes('server-spim'));
      expect(fake.seenEndSession, 42);
      expect(fake.seenPtm, _bytes('server-ptm'));
      expect(fake.seenTk, _bytes('server-tk'));

      // --- request bodies match the spec's exact plist shape ---
      final startBody =
          PropertyListSerialization.propertyListWithString(startRequest!.body)
              as Map<Object?, Object?>;
      expect(startBody['Header'], isA<Map<Object?, Object?>>());
      expect(startBody['Request'], isA<Map<Object?, Object?>>());
      expect((startBody['Request']! as Map<Object?, Object?>).isEmpty, isTrue);
      // package:http appends '; charset=utf-8' automatically when a String
      // body is set - harmless, but assert the base media type rather than
      // the exact header string.
      expect(
        startRequest!.headers['Content-Type'],
        startsWith('text/x-xml-plist'),
      );
      expect(
        startRequest!.headers['X-Apple-I-Client-Time'],
        matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')),
      );

      final finishBody =
          PropertyListSerialization.propertyListWithString(finishRequest!.body)
              as Map<Object?, Object?>;
      expect(
        (finishBody['Request']! as Map<Object?, Object?>)['cpim'],
        base64Encode(_bytes('fake-cpim')),
      );

      // --- persisted state now has provisioned=true + the real routingInfo ---
      final persisted = await AnisetteStateStore(path: statePath).load();
      expect(persisted.provisioned, isTrue);
      expect(persisted.routingInfo, 1234567890123);
      expect(persisted.localUserUid, localUserUid);

      // --- assembled headers ---
      expect(fake.otpCallCount, 1);
      expect(headers['X-Apple-I-MD'], base64Encode(_bytes('otp-1')));
      expect(headers['X-Apple-I-MD-M'], base64Encode(_bytes('mid-1')));
      expect(headers['X-Apple-I-MD-RINFO'], '1234567890123');
      expect(
        headers['X-Apple-I-MD-LU'],
        crypto.sha256
            .convert(utf8.encode(localUserUid))
            .bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase(),
      );
      expect(headers['X-Mme-Device-Id'], localUserUid);
      expect(
        headers['X-MMe-Client-Info'],
        '<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>',
      );
      expect(headers['X-Apple-Locale'], isNotEmpty);
      expect(headers['X-Apple-I-TimeZone'], isNotEmpty);
      expect(
        headers['X-Apple-I-Client-Time'],
        matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')),
      );
    },
  );

  test(
    'skips the provisioning handshake entirely once already provisioned',
    () async {
      const localUserUid = '99999999-8888-4777-8666-555555555555';
      await AnisetteStateStore(path: statePath).save(
        const AnisetteState(
          localUserUid: localUserUid,
          provisioned: true,
          routingInfo: 999,
        ),
      );

      final fake = _RefusingAdiProvisioning();
      final client = MockClient(
        (request) async =>
            throw StateError('unexpected HTTP call to ${request.url}'),
      );

      final provider = AnisetteDataProvider(
        '/fake/adi/lib/dir',
        httpClient: client,
        stateStore: AnisetteStateStore(path: statePath),
        adiFactory:
            ({
              required adiLibraryDirectory,
              required provisioningPath,
              required identifier,
            }) => fake,
      );

      final headers = await provider.fetchAnisetteHeaders();

      expect(headers['X-Apple-I-MD-RINFO'], '999');
      expect(headers['X-Apple-I-MD'], base64Encode(_bytes('cached-otp')));
      expect(headers['X-Mme-Device-Id'], localUserUid);
    },
  );

  test(
    'throws a clear error when local state disagrees with ADI-reported provisioning',
    () async {
      await AnisetteStateStore(path: statePath).save(
        const AnisetteState(
          localUserUid: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
        ),
      );

      final client = MockClient(
        (request) async =>
            throw StateError('unexpected HTTP call to ${request.url}'),
      );

      final provider = AnisetteDataProvider(
        '/fake/adi/lib/dir',
        httpClient: client,
        stateStore: AnisetteStateStore(path: statePath),
        adiFactory:
            ({
              required adiLibraryDirectory,
              required provisioningPath,
              required identifier,
            }) => FakeAdiProvisioning(alreadyProvisioned: true),
      );

      await expectLater(
        provider.fetchAnisetteHeaders,
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('already provisioned'),
          ),
        ),
      );
    },
  );
}
