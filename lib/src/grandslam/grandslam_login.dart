/// GrandSlam SRP login (`o=init`/`o=complete`) plus two-factor
/// authentication (SMS and trusted-device push), producing a
/// [GrandSlamLoginData]. This is layer 2b of Apple ID (email+password)
/// login; it does NOT implement the `o=apptokens` Developer-Services app
/// token exchange (a separate, later layer).
///
/// A faithful port of xtool's `GrandSlamAuthenticateOperation` +
/// `GrandSlamTwoFactorAuthenticateOperation` (`Sources/XKit/GrandSlam/
/// Operations/*.swift`) and the concrete request builders under
/// `Sources/XKit/GrandSlam/Requests/**` (fetched directly from
/// https://github.com/xtool-org/xtool at port time). See the doc comments
/// below for the handful of points where this port deliberately diverges
/// from - or had to resolve ambiguity beyond - that source.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:xcross/src/grandslam/grandslam_login_data.dart';
import 'package:xcross/src/grandslam/grandslam_operation.dart';
import 'package:xcross/src/grandslam/grandslam_response.dart';
import 'package:xcross/src/grandslam/srp_client.dart';
import 'package:xcross/src/util/apple_http_client.dart';
import 'package:xcross/src/util/errors.dart';

/// Which channel a two-factor code was (or, for [unspecified], may have
/// been) sent through - surfaced to [FetchTwoFactorCode] so a caller can
/// print an appropriate prompt before asking the user for the code.
enum GrandSlamTwoFactorMode {
  /// A code was sent via SMS (`o=complete`'s `url` was `secondaryAuth`).
  sms,

  /// A push notification was sent to a trusted device (`url` was
  /// `trustedDeviceSecondaryAuth`).
  trustedDevice,

  /// `o=complete` reported 2FA was required without naming a channel
  /// (`url` absent/null) - GrandSlam considers 2FA already triggered by
  /// some other means. Present a generic "enter your verification code"
  /// prompt.
  unspecified,
}

/// Prompts the user for the 6-digit two-factor code, given which [mode]
/// triggered it. Returns the code, or `null` to cancel. Matches xtool's
/// `TwoFactorAuthDelegate.fetchCode()`; the actual terminal-prompt UI is a
/// later, CLI-layer concern - this is only the extension point.
typedef FetchTwoFactorCode =
    Future<String?> Function(GrandSlamTwoFactorMode mode);

/// The GrandSlam server rejected the client's `M1` (server `hamk`
/// verification failed - almost always an incorrect password), or the
/// two-factor retry loop failed a second time.
class GrandSlamAuthError extends XcrossError {
  GrandSlamAuthError(super.message);
}

/// `o=complete` (or a 2FA-retry `o=complete`) reported 2FA is required,
/// but no [FetchTwoFactorCode] callback was supplied to [GrandSlamClient.login].
class GrandSlamTwoFactorRequiredError extends XcrossError {
  GrandSlamTwoFactorRequiredError(super.message);
}

/// [FetchTwoFactorCode] returned `null` (user cancelled).
class GrandSlamTwoFactorCancelledError extends XcrossError {
  GrandSlamTwoFactorCancelledError(super.message);
}

/// The 2FA code-validation endpoint returned error `-21669`: an incorrect
/// verification code. Distinguished from other [GrandSlamOperationError]s
/// so a caller can re-prompt for the code instead of aborting.
class GrandSlamIncorrectCodeError extends XcrossError {
  GrandSlamIncorrectCodeError(super.message);
}

/// SRP protocol variants offered in `o=init`'s `ps` parameter, in xtool's
/// `GrandSlamAuthProtocol.allCases` order. Also joined with `,` as the
/// first thing fed into the negotiated-protocol digest (see
/// [GrandSlamClient._authenticate]).
const List<String> _srpProtocols = ['s2k', 's2k_fo'];

/// xtool hard-codes phone selection to `"1"` (`// TODO: parse phone number
/// list from o=complete req?`) - no multi-phone-number support. Matched
/// here deliberately, not a bug to "fix" in this port.
const String _smsPhoneNumberId = '1';

/// `X-Xcode-Version` sent on every two-factor request. Verified directly
/// against xtool's `DeviceInfo.swift` (`public static let xcodeVersion =
/// "14.2 (14C18)"`) at port time - NOT the `"16.2 (16C5031c)"` value the
/// task brief suggested reusing from "prior research"; no such value
/// exists anywhere else in this codebase (grepped `lib/`/`test/` to
/// confirm), so it was likely misremembered. Using the source-verified
/// value instead of guessing.
const String _xcodeVersion = '14.2 (14C18)';

/// GrandSlam SRP login + two-factor authentication client.
///
/// Callers are expected to have already resolved [endpoints] (e.g. via
/// [AnisetteDataProvider] / `fetchGrandSlamEndpoints`, layer 2a) and to
/// supply a way to fetch fresh Anisette headers
/// ([AnisetteDataProvider.fetchAnisetteHeaders]) - this class deliberately
/// takes that as a plain callback rather than depending on
/// `AnisetteDataProvider` directly, both to avoid a network-endpoint
/// double-lookup and to keep this class trivially testable (see
/// `test/grandslam/grandslam_login_test.dart`'s fake).
class GrandSlamClient {
  GrandSlamClient({
    required this.endpoints,
    required Future<Map<String, String>> Function() fetchAnisetteHeaders,
    http.Client? httpClient,
    this.locale = 'en_US',
  }) : _fetchAnisetteHeaders = fetchAnisetteHeaders,
       _http = httpClient ?? createAppleHttpClient();

  final GrandSlamEndpoints endpoints;

  /// `cpd`'s `loc` field. Defaults to `en_US`; callers with a real system
  /// locale (see `anisette_data_provider.dart`'s `_systemLocale()`) may
  /// want to pass that instead.
  final String locale;

  final Future<Map<String, String>> Function() _fetchAnisetteHeaders;
  final http.Client _http;

  /// Releases the underlying HTTP client's resources.
  void close() => _http.close();

  /// Performs the full GrandSlam SRP login handshake, including 2FA if
  /// required. The Apple ID [username] is lowercased before use (GrandSlam
  /// requires this for SRP - confirmed via xtool's
  /// `DeveloperServicesLoginManager`, which lowercases once and reuses
  /// that value for both the `o=...` requests' `u` field and the SRP math
  /// itself, not just the SRP math alone).
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
    final srp = SrpClient();

    // Negotiated-protocol digest sequencing, resolved by reading xtool's
    // `GrandSlamAuthenticateOperation.authenticate(isRetry:)` directly
    // (not guessable from `SrpClient`'s own doc comments, which
    // explicitly defer this to "the caller"): addString(offered
    // protocols joined by ","), then "|" before AND after each
    // request/response boundary, with the response payloads addData'd in
    // between. `srp_client.dart` is left untouched; only this
    // orchestration-layer sequencing is new.
    srp.addString(_srpProtocols.join(','));
    srp.addString('|');

    final initResponse = await _postOperation(
      operation: 'init',
      username: username,
      extraParams: {'ps': _srpProtocols, 'A2k': byteDataOf(srp.publicKey)},
    );

    final selectedProtocol = stringField(initResponse, 'sp');
    final cookie = stringField(initResponse, 'c');
    final salt = dataField(initResponse, 's');
    final iterations = intField(initResponse, 'i');
    final serverPublicKey = dataField(initResponse, 'B');

    srp.addString('|');
    srp.addString(selectedProtocol);

    final m1 = srp.processChallenge(
      username: username,
      password: password,
      salt: salt,
      iterations: iterations,
      isLegacyProtocol: selectedProtocol == 's2k_fo',
      serverPublicKey: serverPublicKey,
    );

    final completeResponse = await _postOperation(
      operation: 'complete',
      username: username,
      extraParams: {'c': cookie, 'M1': byteDataOf(m1)},
    );

    final hamk = dataField(completeResponse, 'M2');
    final spd = dataField(completeResponse, 'spd');
    final negProto = dataField(completeResponse, 'np');
    final sc = optionalDataField(completeResponse, 'sc');

    srp.addString('|');
    srp.addData(spd);
    srp.addString('|');
    if (sc != null) srp.addData(sc);
    srp.addString('|');

    if (!srp.verifyServerProof(hamk)) {
      throw GrandSlamAuthError(
        'GrandSlam rejected the SRP proof (server hamk mismatch) - most '
        'likely an incorrect password.',
      );
    }
    if (!srp.verifyNegotiatedProtocols(negProto)) {
      throw GrandSlamAuthError(
        'GrandSlam negotiated-protocol verification (negProto) failed.',
      );
    }

    final decrypted = utf8.decode(srp.decryptCbc(spd));
    final payload = decodePlist(decrypted, context: "decrypted 'spd' payload");

    final statusCode = payload['status-code'];
    if (statusCode == 409) {
      if (isRetry) {
        throw GrandSlamAuthError(
          '2FA is still being requested after a full login retry - '
          'aborting instead of looping indefinitely.',
        );
      }
      // Apple's server includes adsid/GsIdmsToken/sk/c in the decrypted
      // payload even at this intermediate 2FA-required stage (confirmed:
      // xtool's `GrandSlamAuthenticateOperation` unconditionally decodes
      // `GrandSlamLoginData` from the same `rawLoginResponse`, with no
      // optionality/try? guard) - adsid/idmsToken are needed here for
      // `identityToken`, the 2FA requests' auth header.
      final loginData = GrandSlamLoginData.fromDecryptedPlist(payload);
      final modeUrl = payload['url'];
      await _performTwoFactor(
        modeUrl: modeUrl is String ? modeUrl : null,
        loginData: loginData,
        fetchTwoFactorCode: fetchTwoFactorCode,
      );
      return _authenticate(
        username: username,
        password: password,
        fetchTwoFactorCode: fetchTwoFactorCode,
        isRetry: true,
      );
    }

    return GrandSlamLoginData.fromDecryptedPlist(payload);
  }

  // --- o=init / o=complete -------------------------------------------

  Future<Map<String, Object?>> _postOperation({
    required String operation,
    required String username,
    required Map<String, Object?> extraParams,
  }) => postGrandSlamOperation(
    httpClient: _http,
    gsService: endpoints.gsService,
    operation: operation,
    username: username,
    fetchAnisetteHeaders: _fetchAnisetteHeaders,
    extraParams: extraParams,
    locale: locale,
  );

  // --- two-factor authentication --------------------------------------

  Future<void> _performTwoFactor({
    required String? modeUrl,
    required GrandSlamLoginData loginData,
    required FetchTwoFactorCode? fetchTwoFactorCode,
  }) async {
    switch (modeUrl) {
      case 'secondaryAuth':
        await _performSmsAuth(loginData, fetchTwoFactorCode);
      case 'trustedDeviceSecondaryAuth':
        await _performTrustedDeviceAuth(loginData, fetchTwoFactorCode);
      default:
        // `url` absent/null/unrecognized: 2FA already implicitly
        // triggered by GrandSlam itself - go straight to code validation.
        await _validateCode(
          loginData: loginData,
          fetchTwoFactorCode: fetchTwoFactorCode,
          phoneNumberId: null,
          promptedMode: GrandSlamTwoFactorMode.unspecified,
        );
    }
  }

  Future<void> _performSmsAuth(
    GrandSlamLoginData loginData,
    FetchTwoFactorCode? fetchTwoFactorCode,
  ) async {
    final body = PropertyListSerialization.stringWithPropertyList({
      'serverInfo': {'phoneNumber.id': _smsPhoneNumberId},
    });
    final response = await _postTwoFactor(
      Uri.parse('https://gsa.apple.com/auth/verify/phone/put?mode=sms'),
      loginData,
      body,
    );
    _checkTwoFactorResponse(response);
    await _validateCode(
      loginData: loginData,
      fetchTwoFactorCode: fetchTwoFactorCode,
      phoneNumberId: _smsPhoneNumberId,
      promptedMode: GrandSlamTwoFactorMode.sms,
    );
  }

  Future<void> _performTrustedDeviceAuth(
    GrandSlamLoginData loginData,
    FetchTwoFactorCode? fetchTwoFactorCode,
  ) async {
    final response = await _getTwoFactor(
      Uri.parse(endpoints.trustedDeviceSecondaryAuth),
      loginData,
    );
    _checkTwoFactorResponse(response);
    await _validateCode(
      loginData: loginData,
      fetchTwoFactorCode: fetchTwoFactorCode,
      phoneNumberId: null,
      promptedMode: GrandSlamTwoFactorMode.trustedDevice,
    );
  }

  Future<void> _validateCode({
    required GrandSlamLoginData loginData,
    required FetchTwoFactorCode? fetchTwoFactorCode,
    required String? phoneNumberId,
    required GrandSlamTwoFactorMode promptedMode,
  }) async {
    if (fetchTwoFactorCode == null) {
      throw GrandSlamTwoFactorRequiredError(
        'GrandSlam requires two-factor authentication, but no '
        'fetchTwoFactorCode callback was provided to GrandSlamClient.login().',
      );
    }
    final code = await fetchTwoFactorCode(promptedMode);
    if (code == null) {
      throw GrandSlamTwoFactorCancelledError(
        'Two-factor authentication was cancelled.',
      );
    }

    final http.Response response;
    if (phoneNumberId != null) {
      // SMS path: code is sent in the plist body, not a header.
      final body = PropertyListSerialization.stringWithPropertyList({
        'securityCode.code': code,
        'serverInfo': {'mode': 'sms', 'phoneNumber.id': phoneNumberId},
      });
      response = await _postTwoFactor(
        Uri.parse(
          'https://gsa.apple.com/auth/verify/phone/securitycode'
          '?referrer=/auth/verify/phone/put',
        ),
        loginData,
        body,
      );
    } else {
      // Trusted-device / implicit path: code is an HTTP header, and this
      // is a GET (verified directly against xtool's `GrandSlamValidateRequest`,
      // which does not override the `GrandSlamTwoFactorRequest` default
      // `.get` method - despite this task's brief describing it as a
      // POST; trusting the source over the brief here).
      response = await _getTwoFactor(
        Uri.parse(endpoints.validateCode),
        loginData,
        extraHeaders: {'security-code': code},
      );
    }
    _checkTwoFactorResponse(response, incorrectCodeMeansWrongCode: true);
  }

  Map<String, String> _twoFactorHeaders(
    Map<String, String> anisette,
    GrandSlamLoginData loginData, {
    Map<String, String> extraHeaders = const {},
  }) => {
    ...anisette,
    'Content-Type': 'application/x-plist',
    'Accept': 'application/x-buddyml',
    'X-Apple-App-Info': 'com.apple.gs.xcode.auth',
    'X-Xcode-Version': _xcodeVersion,
    'X-Apple-Identity-Token': loginData.identityToken,
    ...extraHeaders,
  };

  Future<http.Response> _postTwoFactor(
    Uri url,
    GrandSlamLoginData loginData,
    String body,
  ) async {
    final anisette = await _fetchAnisetteHeaders();
    return sendGrandSlamRequest(
      _http,
      method: 'POST',
      url: url.toString(),
      operation: 'two-factor POST',
      headers: _twoFactorHeaders(anisette, loginData),
      body: body,
    );
  }

  Future<http.Response> _getTwoFactor(
    Uri url,
    GrandSlamLoginData loginData, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final anisette = await _fetchAnisetteHeaders();
    return sendGrandSlamRequest(
      _http,
      method: 'GET',
      url: url.toString(),
      operation: 'two-factor GET',
      headers: _twoFactorHeaders(
        anisette,
        loginData,
        extraHeaders: extraHeaders,
      ),
    );
  }

  /// Checks a two-factor HTTP response for the `-21669` "incorrect
  /// verification code" error. xtool's own `Decoder`s for these endpoints
  /// are no-ops (`static func decode(data: Data) throws {}` - they never
  /// even look at the body), so its `catch let error as
  /// GrandSlamOperationError where error.code == -21669` in
  /// `GrandSlamTwoFactorAuthenticateOperation.validateCode` is
  /// unreachable dead code in the real library. Implemented for real
  /// here (reusing the same `Status.ec`/`em` envelope shape the `o=...`
  /// operations use, since that's a protocol-wide convention, not an
  /// operation-specific one) so the interactive-2FA feature this task
  /// asks for actually works. Tolerant of a non-plist/empty body (e.g.
  /// the trusted-device push returns `application/x-buddyml`).
  void _checkTwoFactorResponse(
    http.Response response, {
    bool incorrectCodeMeansWrongCode = false,
  }) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw XcrossError(
        'GrandSlam two-factor request to ${response.request?.url} failed '
        '(HTTP ${response.statusCode})',
      );
    }
    final body = response.body.trim();
    if (body.isEmpty || !_looksLikeXmlPlist(body)) return;

    final Object decoded;
    try {
      decoded = PropertyListSerialization.propertyListWithString(body);
    } on PropertyListException {
      return; // Malformed plist-looking body - nothing to check.
    }
    if (decoded is! Map) return;
    final status = decoded['Status'];
    if (status is! Map) return;
    final ec = status['ec'];
    if (ec is! int || ec == 0) return;
    final em = '${status['em'] ?? 'unknown error'}';
    if (incorrectCodeMeansWrongCode && ec == -21669) {
      throw GrandSlamIncorrectCodeError(em);
    }
    throw GrandSlamOperationError(ec, em);
  }

  /// `propertylistserialization` prints a stack before throwing when the
  /// body is not XML plist (e.g. x-buddyml). Sniff first to avoid that noise.
  static bool _looksLikeXmlPlist(String body) {
    final start = body.trimLeft();
    return start.startsWith('<?xml') || start.startsWith('<plist');
  }
}
