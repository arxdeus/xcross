/// GrandSlam `o=apptokens` exchange: turns a successful SRP login
/// ([GrandSlamLoginData]) into the Developer Services app token used by
/// the native signing pipeline.
///
/// The AES-GCM blob layout is source-verified against xtool's
/// `AppTokens.swift`. That file attributes the construction to Apple's
/// private `AppleIDAuthSupport` (`_AppleIDAuthSupportCreateDecryptedData`),
/// so this is a faithful xtool port, not an independently documented Apple
/// API.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/apple_http_client.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_login_data.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_operation.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_response.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;

const String kDeveloperServicesAppIdentifier = 'com.apple.gs.xcode.auth';

class DeveloperServicesLoginToken {
  const DeveloperServicesLoginToken({
    required this.adsid,
    required this.token,
    required this.expiry,
  });

  final String adsid;
  final String token;

  /// UTC expiry time decoded from Apple's millisecond epoch value.
  final DateTime expiry;

  bool get isExpired => !DateTime.now().toUtc().isBefore(expiry.toUtc());
}

class GrandSlamAppTokenExchange {
  GrandSlamAppTokenExchange({
    required this.endpoints,
    required Future<Map<String, String>> Function() fetchAnisetteHeaders,
    http.Client? httpClient,
    this.locale = 'en_US',
  }) : _fetchAnisetteHeaders = fetchAnisetteHeaders,
       _http = httpClient ?? AppleHttp.createAppleHttpClient();

  final GrandSlamEndpoints endpoints;
  final String locale;

  final Future<Map<String, String>> Function() _fetchAnisetteHeaders;
  final http.Client _http;

  void close() => _http.close();

  Future<DeveloperServicesLoginToken> exchange(
    GrandSlamLoginData loginData, {
    List<String> apps = const [kDeveloperServicesAppIdentifier],
  }) async {
    if (!apps.contains(kDeveloperServicesAppIdentifier)) {
      throw AppleError(
        'Developer Services app-token exchange must request '
        '$kDeveloperServicesAppIdentifier.',
      );
    }

    final response = await GrandSlamOperation.postGrandSlamOperation(
      httpClient: _http,
      gsService: endpoints.gsService,
      operation: 'apptokens',
      username: loginData.adsid,
      fetchAnisetteHeaders: _fetchAnisetteHeaders,
      locale: locale,
      extraParams: {
        'app': apps,
        'c': GrandSlamResponse.byteDataOf(loginData.cookie),
        't': loginData.idmsToken,
        'checksum': GrandSlamResponse.byteDataOf(
          GrandSlamAppTokenExchange.grandSlamAppTokenChecksum(
            sessionKey: loginData.sessionKey,
            adsid: loginData.adsid,
            apps: apps,
          ),
        ),
      },
    );

    final encryptedToken = GrandSlamResponse.dataField(response, 'et');
    final decrypted = GrandSlamAppTokenExchange.decryptGrandSlamAppTokenBlob(
      encryptedToken: encryptedToken,
      sessionKey: loginData.sessionKey,
    );
    final plist = GrandSlamResponse.decodePlistBytes(
      decrypted,
      context: "decrypted 'et' payload",
    );
    return _parseToken(plist, loginData.adsid, kDeveloperServicesAppIdentifier);
  }

  /// xtool/AppTokens.swift checksum order:
  /// HMAC-SHA256(SK, "apptokens" || adsid || app[0] || app[1] || ...).
  static Uint8List grandSlamAppTokenChecksum({
    required Uint8List sessionKey,
    required String adsid,
    required List<String> apps,
  }) {
    final bytes = <int>[
      ...utf8.encode('apptokens'),
      ...utf8.encode(adsid),
      for (final app in apps) ...utf8.encode(app),
    ];
    return Uint8List.fromList(
      crypto.Hmac(crypto.sha256, sessionKey).convert(bytes).bytes,
    );
  }

  static Uint8List decryptGrandSlamAppTokenBlob({
    required Uint8List encryptedToken,
    required Uint8List sessionKey,
  }) {
    const aadLength = 3;
    const ivLength = 16;
    const tagLength = 16;
    if (sessionKey.length != 32) {
      throw AppleError(
        'GrandSlam app-token decrypt expected a 32-byte session key; '
        'got ${sessionKey.length} bytes.',
      );
    }
    if (encryptedToken.length <= aadLength + ivLength + tagLength) {
      throw AppleError('GrandSlam app-token encrypted blob is too short.');
    }

    final aad = Uint8List.sublistView(encryptedToken, 0, aadLength);
    final iv = Uint8List.sublistView(
      encryptedToken,
      aadLength,
      aadLength + ivLength,
    );
    final ciphertext = Uint8List.sublistView(
      encryptedToken,
      aadLength + ivLength,
      encryptedToken.length - tagLength,
    );
    final tag = Uint8List.sublistView(
      encryptedToken,
      encryptedToken.length - tagLength,
    );
    final sealed = Uint8List(ciphertext.length + tag.length)
      ..setAll(0, ciphertext)
      ..setAll(ciphertext.length, tag);

    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        false,
        pc.AEADParameters(pc.KeyParameter(sessionKey), tagLength * 8, iv, aad),
      );
    try {
      return cipher.process(sealed);
    } on pc.InvalidCipherTextException catch (e) {
      throw AppleError('GrandSlam app-token AES-GCM authentication failed: $e');
    }
  }

  static DeveloperServicesLoginToken _parseToken(
    Map<String, Object?> plist,
    String adsid,
    String appIdentifier,
  ) {
    final tokens = _stringMap(plist['t'], "decrypted 'et' payload token map");
    final appToken = _stringMap(tokens[appIdentifier], appIdentifier);
    return DeveloperServicesLoginToken(
      adsid: adsid,
      token: GrandSlamResponse.stringField(appToken, 'token'),
      expiry: DateTime.fromMillisecondsSinceEpoch(
        GrandSlamResponse.intField(appToken, 'expiry'),
        isUtc: true,
      ),
    );
  }

  static Map<String, Object?> _stringMap(Object? value, String context) {
    if (value is! Map) {
      throw AppleError('GrandSlam app-token response missing $context');
    }
    return value.cast<String, Object?>();
  }
}
