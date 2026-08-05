/// The two-factor half of GrandSlam login: sending the code (SMS or
/// trusted-device push) and validating what the user types back.
///
/// Ported from xtool's `GrandSlamTwoFactorAuthenticateOperation` and the
/// request builders under `Sources/XKit/GrandSlam/Requests/**`. Driven by
/// [GrandSlamClient] when `o=complete` answers with `status-code` 409;
/// `grandslam_login.dart` re-exports everything public here.
library;

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_login_data.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_response.dart';
import 'package:http/http.dart' as http;
import 'package:propertylistserialization/propertylistserialization.dart';

/// Which channel a two-factor code was (or, for [unspecified], may have
/// been) sent through, so a caller can print a fitting prompt.
enum GrandSlamTwoFactorMode {
  /// Sent by SMS - `o=complete`'s `url` was `secondaryAuth`.
  sms,

  /// Pushed to a trusted device - `url` was `trustedDeviceSecondaryAuth`.
  trustedDevice,

  /// 2FA was required without naming a channel (`url` absent), meaning
  /// GrandSlam considers it already triggered. Prompt generically.
  unspecified,
}

/// Prompts the user for the 6-digit code, returning `null` to cancel.
/// The terminal UI itself is a CLI-layer concern; this is the hook.
typedef FetchTwoFactorCode =
    Future<String?> Function(GrandSlamTwoFactorMode mode);

/// Two-factor authentication is required, but no [FetchTwoFactorCode] was
/// supplied to `GrandSlamClient.login`.
class GrandSlamTwoFactorRequiredError extends AppleError {
  const GrandSlamTwoFactorRequiredError(super.message);
}

/// [FetchTwoFactorCode] returned `null` - the user cancelled.
class GrandSlamTwoFactorCancelledError extends AppleError {
  const GrandSlamTwoFactorCancelledError(super.message);
}

/// The code-validation endpoint returned `-21669`, an incorrect
/// verification code. Kept distinct from other [GrandSlamOperationError]s
/// so a caller can re-prompt instead of aborting.
class GrandSlamIncorrectCodeError extends AppleError {
  const GrandSlamIncorrectCodeError(super.message);
}

/// `Status.ec` for "incorrect verification code".
const int _incorrectCodeErrorCode = -21_669;

/// xtool hard-codes phone selection to `"1"` - no multi-number support.
/// Matched deliberately; not a bug to "fix" in this port.
const String _smsPhoneNumberId = '1';

/// `X-Xcode-Version` for every two-factor request, taken verbatim from
/// xtool's `DeviceInfo.swift`.
const String _xcodeVersion = '14.2 (14C18)';

const String _smsPutUrl =
    'https://gsa.apple.com/auth/verify/phone/put?mode=sms';

const String _smsValidateUrl =
    'https://gsa.apple.com/auth/verify/phone/securitycode'
    '?referrer=/auth/verify/phone/put';

/// Runs one two-factor round: trigger the code, then validate it.
class GrandSlamTwoFactor {
  const GrandSlamTwoFactor({
    required this.endpoints,
    required this.httpClient,
    required this.fetchAnisetteHeaders,
    required this.fetchCode,
  });

  final GrandSlamEndpoints endpoints;
  final http.Client httpClient;
  final Future<Map<String, String>> Function() fetchAnisetteHeaders;
  final FetchTwoFactorCode? fetchCode;

  /// Dispatches on `o=complete`'s `url` field. An absent or unrecognized
  /// value means GrandSlam already triggered 2FA by other means, so the
  /// code can be validated straight away.
  Future<void> authenticate({
    required String? modeUrl,
    required GrandSlamLoginData loginData,
  }) => switch (modeUrl) {
    'secondaryAuth' => _sendSmsCode(loginData),
    'trustedDeviceSecondaryAuth' => _sendTrustedDevicePush(loginData),
    _ => _validateCode(
      loginData: loginData,
      phoneNumberId: null,
      promptedMode: GrandSlamTwoFactorMode.unspecified,
    ),
  };

  Future<void> _sendSmsCode(GrandSlamLoginData loginData) async {
    final response = await _send(
      method: 'POST',
      url: _smsPutUrl,
      loginData: loginData,
      body: PropertyListSerialization.stringWithPropertyList({
        'serverInfo': {'phoneNumber.id': _smsPhoneNumberId},
      }),
    );
    _ensureAccepted(response);
    await _validateCode(
      loginData: loginData,
      phoneNumberId: _smsPhoneNumberId,
      promptedMode: GrandSlamTwoFactorMode.sms,
    );
  }

  Future<void> _sendTrustedDevicePush(GrandSlamLoginData loginData) async {
    final response = await _send(
      method: 'GET',
      url: endpoints.trustedDeviceSecondaryAuth,
      loginData: loginData,
    );
    _ensureAccepted(response);
    await _validateCode(
      loginData: loginData,
      phoneNumberId: null,
      promptedMode: GrandSlamTwoFactorMode.trustedDevice,
    );
  }

  Future<void> _validateCode({
    required GrandSlamLoginData loginData,
    required String? phoneNumberId,
    required GrandSlamTwoFactorMode promptedMode,
  }) async {
    final prompt = fetchCode;
    if (prompt == null) {
      throw const GrandSlamTwoFactorRequiredError(
        'GrandSlam requires two-factor authentication, but no '
        'fetchTwoFactorCode callback was provided to GrandSlamClient.login().',
      );
    }
    final code = await prompt(promptedMode);
    if (code == null) {
      throw const GrandSlamTwoFactorCancelledError(
        'Two-factor authentication was cancelled.',
      );
    }

    // SMS carries the code in the plist body; the trusted-device and
    // implicit paths carry it in a header on a GET (verified against
    // xtool's `GrandSlamValidateRequest`, which keeps the base request's
    // `.get` method).
    final response = phoneNumberId == null
        ? await _send(
            method: 'GET',
            url: endpoints.validateCode,
            loginData: loginData,
            extraHeaders: {'security-code': code},
          )
        : await _send(
            method: 'POST',
            url: _smsValidateUrl,
            loginData: loginData,
            body: PropertyListSerialization.stringWithPropertyList({
              'securityCode.code': code,
              'serverInfo': {'mode': 'sms', 'phoneNumber.id': phoneNumberId},
            }),
          );
    _ensureAccepted(response, wrongCodeIsRecoverable: true);
  }

  Future<http.Response> _send({
    required String method,
    required String url,
    required GrandSlamLoginData loginData,
    Map<String, String> extraHeaders = const {},
    String? body,
  }) async {
    final anisette = await fetchAnisetteHeaders();
    return GrandSlamEndpoints.sendGrandSlamRequest(
      httpClient,
      method: method,
      url: url,
      operation: 'two-factor $method',
      headers: {
        ...anisette,
        'Content-Type': 'application/x-plist',
        'Accept': 'application/x-buddyml',
        'X-Apple-App-Info': 'com.apple.gs.xcode.auth',
        'X-Xcode-Version': _xcodeVersion,
        'X-Apple-Identity-Token': loginData.identityToken,
        ...extraHeaders,
      },
      body: body,
    );
  }

  /// Rejects a non-2xx response, then looks for the protocol-wide
  /// `Status.ec`/`em` envelope in the body.
  ///
  /// xtool never inspects these bodies (its decoders are empty), which
  /// makes its own `-21669` handler unreachable; it is implemented for
  /// real here so interactive 2FA can re-prompt. Bodies that are empty or
  /// not XML plist (the trusted-device push answers `x-buddyml`) are
  /// tolerated.
  static void _ensureAccepted(
    http.Response response, {
    bool wrongCodeIsRecoverable = false,
  }) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleError(
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
      return; // Plist-shaped but malformed - nothing to check.
    }
    if (decoded is! Map<Object?, Object?>) return;
    final status = decoded['Status'];
    if (status is! Map<Object?, Object?>) return;
    final code = status['ec'];
    if (code is! int || code == 0) return;

    final message = '${status['em'] ?? 'unknown error'}';
    if (wrongCodeIsRecoverable && code == _incorrectCodeErrorCode) {
      throw GrandSlamIncorrectCodeError(message);
    }
    throw GrandSlamOperationError(code, message);
  }

  /// `propertylistserialization` prints a stack trace before throwing on
  /// non-XML input (e.g. x-buddyml); sniff first to avoid that noise.
  static bool _looksLikeXmlPlist(String body) =>
      body.startsWith('<?xml') || body.startsWith('<plist');
}
