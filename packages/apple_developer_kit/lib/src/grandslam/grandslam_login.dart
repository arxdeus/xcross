/// GrandSlam SRP login: `o=init`, `o=complete`, and the two-factor
/// round-trip that some accounts require in between, producing a
/// [GrandSlamLoginData]. The `o=apptokens` Developer Services exchange
/// lives in `app_token_exchange.dart`.
///
/// Ported from xtool's `GrandSlamAuthenticateOperation` and the request
/// builders under `Sources/XKit/GrandSlam/Requests/**`.
library;

import 'dart:convert';

import 'package:apple_developer_kit/src/apple_http_client.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_login_data.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_operation.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_two_factor.dart';
import 'package:apple_developer_kit/src/grandslam/internal/grandslam_response_decoder.dart';
import 'package:apple_developer_kit/src/grandslam/internal/srp_challenge.dart';
import 'package:apple_developer_kit/src/grandslam/srp_client.dart';
import 'package:http/http.dart' as http;

/// SRP variants offered in `o=init`'s `ps`, in xtool's
/// `GrandSlamAuthProtocol.allCases` order. The same list, comma-joined, is
/// the first thing fed into the negotiated-protocol digest.
const List<String> _srpProtocols = ['s2k', 's2k_fo'];

/// `o=complete`'s `status-code` meaning "two-factor authentication first".
const int _twoFactorRequiredStatus = 409;

/// GrandSlam rejected the client's `M1` (the server `hamk` did not
/// verify - almost always a wrong password), or two-factor was still
/// demanded after a full retry.
final class GrandSlamAuthError extends AppleError {
  const GrandSlamAuthError(super.message);
}

/// GrandSlam SRP login client.
///
/// [endpoints] is expected to be resolved already (see
/// `AnisetteProvider.resolveGrandSlamEndpoints`). Anisette headers arrive
/// through a plain callback rather than an `AnisetteDataProvider`
/// dependency, which avoids a second endpoint lookup and keeps this class
/// trivially fakeable in tests.
final class GrandSlamClient {
  GrandSlamClient({
    required this.endpoints,
    required Future<Map<String, String>> Function() fetchAnisetteHeaders,
    http.Client? httpClient,
    this.locale = 'en_US',
  }) : _fetchAnisetteHeaders = fetchAnisetteHeaders,
       _http = httpClient ?? AppleHttp.createAppleHttpClient();

  final GrandSlamEndpoints endpoints;

  /// `cpd`'s `loc` field. Callers with a real system locale (see
  /// `AnisetteHeaders.anisetteSystemLocale`) may want to pass that.
  final String locale;

  final Future<Map<String, String>> Function() _fetchAnisetteHeaders;
  final http.Client _http;

  /// Releases the underlying HTTP client's resources.
  void close() => _http.close();

  /// Runs the full SRP handshake, including two-factor if GrandSlam asks
  /// for it.
  ///
  /// [username] is lowercased first: GrandSlam requires the same lowercased
  /// value in both the `o=...` requests' `u` field and the SRP math.
  Future<GrandSlamLoginData> login({
    required String username,
    required String password,
    FetchTwoFactorCode? fetchTwoFactorCode,
  }) => _authenticate(
    username: username.toLowerCase(),
    password: password,
    fetchTwoFactorCode: fetchTwoFactorCode,
    isRetry: false,
  );

  Future<GrandSlamLoginData> _authenticate({
    required String username,
    required String password,
    required FetchTwoFactorCode? fetchTwoFactorCode,
    required bool isRetry,
  }) async {
    // Digest sequencing, read straight out of xtool's
    // `GrandSlamAuthenticateOperation.authenticate(isRetry:)`: the offered
    // protocols, then a "|" separator on both sides of every
    // request/response boundary with the response payloads in between.
    final srp = SrpClient()
      ..addString(_srpProtocols.join(','))
      ..addString('|');

    final challenge = await _requestSrpInit(srp, username);
    final payload = await _completeSrpProof(
      srp: srp,
      username: username,
      password: password,
      challenge: challenge,
    );

    if (payload['status-code'] != _twoFactorRequiredStatus) {
      return GrandSlamLoginData.fromDecryptedPlist(payload);
    }
    if (isRetry) {
      throw const GrandSlamAuthError(
        '2FA is still being requested after a full login retry - '
        'aborting instead of looping indefinitely.',
      );
    }

    // Apple populates adsid/GsIdmsToken/sk/c even at this intermediate
    // stage, and the two-factor requests need them for `identityToken`.
    await _twoFactor(fetchTwoFactorCode).authenticate(
      modeUrl: switch (payload['url']) {
        final String url => url,
        _ => null,
      },
      loginData: GrandSlamLoginData.fromDecryptedPlist(payload),
    );

    return _authenticate(
      username: username,
      password: password,
      fetchTwoFactorCode: fetchTwoFactorCode,
      isRetry: true,
    );
  }

  /// `o=init`: publishes `A`, learns the salt, iteration count, chosen
  /// protocol, and the server's `B`.
  Future<SrpChallenge> _requestSrpInit(SrpClient srp, String username) async {
    final response = await _postOperation(
      operation: 'init',
      username: username,
      extraParams: {
        'ps': _srpProtocols,
        'A2k': GrandSlamResponse.byteDataOf(srp.publicKey),
      },
    );

    final protocol = GrandSlamResponse.stringField(response, 'sp');
    srp
      ..addString('|')
      ..addString(protocol);

    return SrpChallenge(
      protocol: protocol,
      cookie: GrandSlamResponse.stringField(response, 'c'),
      salt: GrandSlamResponse.dataField(response, 's'),
      iterations: GrandSlamResponse.intField(response, 'i'),
      serverPublicKey: GrandSlamResponse.dataField(response, 'B'),
    );
  }

  /// `o=complete`: proves knowledge of the password with `M1`, checks the
  /// server's own proofs, and returns the decrypted `spd` payload.
  Future<Map<String, Object?>> _completeSrpProof({
    required SrpClient srp,
    required String username,
    required String password,
    required SrpChallenge challenge,
  }) async {
    final m1 = srp.processChallenge(
      username: username,
      password: password,
      salt: challenge.salt,
      iterations: challenge.iterations,
      isLegacyProtocol: challenge.protocol == 's2k_fo',
      serverPublicKey: challenge.serverPublicKey,
    );

    final response = await _postOperation(
      operation: 'complete',
      username: username,
      extraParams: {
        'c': challenge.cookie,
        'M1': GrandSlamResponse.byteDataOf(m1),
      },
    );

    final hamk = GrandSlamResponse.dataField(response, 'M2');
    final spd = GrandSlamResponse.dataField(response, 'spd');
    final negProto = GrandSlamResponse.dataField(response, 'np');
    final sc = GrandSlamResponse.optionalDataField(response, 'sc');

    srp
      ..addString('|')
      ..addData(spd)
      ..addString('|');
    if (sc != null) srp.addData(sc);
    srp.addString('|');

    if (!srp.verifyServerProof(hamk)) {
      throw const GrandSlamAuthError(
        'GrandSlam rejected the SRP proof (server hamk mismatch) - most '
        'likely an incorrect password.',
      );
    }
    if (!srp.verifyNegotiatedProtocols(negProto)) {
      throw const GrandSlamAuthError(
        'GrandSlam negotiated-protocol verification (negProto) failed.',
      );
    }

    return GrandSlamResponse.decodePlist(
      utf8.decode(srp.decryptCbc(spd)),
      context: "decrypted 'spd' payload",
    );
  }

  Future<Map<String, Object?>> _postOperation({
    required String operation,
    required String username,
    required Map<String, Object?> extraParams,
  }) => GrandSlamOperation.postGrandSlamOperation(
    httpClient: _http,
    gsService: endpoints.gsService,
    operation: operation,
    username: username,
    fetchAnisetteHeaders: _fetchAnisetteHeaders,
    extraParams: extraParams,
    locale: locale,
  );

  GrandSlamTwoFactor _twoFactor(FetchTwoFactorCode? fetchTwoFactorCode) =>
      GrandSlamTwoFactor(
        endpoints: endpoints,
        httpClient: _http,
        fetchAnisetteHeaders: _fetchAnisetteHeaders,
        fetchCode: fetchTwoFactorCode,
      );
}
