/// GrandSlam `o=apptokens`: turns a successful SRP login
/// ([GrandSlamLoginData]) into the Developer Services app token the native
/// signing pipeline uses.
///
/// The AES-GCM blob layout is a faithful port of xtool's `AppTokens.swift`,
/// which in turn attributes it to Apple's private `AppleIDAuthSupport`
/// (`_AppleIDAuthSupportCreateDecryptedData`) - not a documented API.
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

/// Byte layout of the encrypted `et` blob: a 3-byte AAD prefix, a 16-byte
/// IV, the ciphertext, then a 16-byte GCM tag.
const int _aadLength = 3;
const int _ivLength = 16;
const int _tagLength = 16;

/// AES-256: the SRP session key must be exactly 32 bytes.
const int _sessionKeyLength = 32;

class DeveloperServicesLoginToken {
  const DeveloperServicesLoginToken({
    required this.adsid,
    required this.token,
    required this.expiry,
  });

  final String adsid;
  final String token;

  /// UTC expiry decoded from Apple's millisecond epoch value.
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
          grandSlamAppTokenChecksum(
            sessionKey: loginData.sessionKey,
            adsid: loginData.adsid,
            apps: apps,
          ),
        ),
      },
    );

    final decrypted = decryptGrandSlamAppTokenBlob(
      encryptedToken: GrandSlamResponse.dataField(response, 'et'),
      sessionKey: loginData.sessionKey,
    );
    return _parseToken(
      GrandSlamResponse.decodePlistBytes(
        decrypted,
        context: "decrypted 'et' payload",
      ),
      loginData.adsid,
      kDeveloperServicesAppIdentifier,
    );
  }

  /// xtool/AppTokens.swift checksum order:
  /// `HMAC-SHA256(SK, "apptokens" || adsid || app[0] || app[1] || ...)`.
  static Uint8List grandSlamAppTokenChecksum({
    required Uint8List sessionKey,
    required String adsid,
    required List<String> apps,
  }) => Uint8List.fromList(
    crypto.Hmac(crypto.sha256, sessionKey).convert([
      ...utf8.encode('apptokens'),
      ...utf8.encode(adsid),
      for (final app in apps) ...utf8.encode(app),
    ]).bytes,
  );

  /// Opens the `et` blob: AES-256-GCM with the leading 3 bytes as
  /// additional authenticated data.
  static Uint8List decryptGrandSlamAppTokenBlob({
    required Uint8List encryptedToken,
    required Uint8List sessionKey,
  }) {
    if (sessionKey.length != _sessionKeyLength) {
      throw AppleError(
        'GrandSlam app-token decrypt expected a 32-byte session key; '
        'got ${sessionKey.length} bytes.',
      );
    }
    if (encryptedToken.length <= _aadLength + _ivLength + _tagLength) {
      throw AppleError('GrandSlam app-token encrypted blob is too short.');
    }

    final aad = Uint8List.sublistView(encryptedToken, 0, _aadLength);
    final iv = Uint8List.sublistView(
      encryptedToken,
      _aadLength,
      _aadLength + _ivLength,
    );
    // PointyCastle's GCM expects the tag appended to the ciphertext, which
    // is already this blob's layout past the IV. Copied, not viewed: a
    // non-zero-offset view is not safe to hand to PointyCastle.
    final sealed = encryptedToken.sublist(_aadLength + _ivLength);

    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        false,
        pc.AEADParameters(pc.KeyParameter(sessionKey), _tagLength * 8, iv, aad),
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
