import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/shared/grandslam/grandslam_response.dart';

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
final class GrandSlamTwoFactorRequiredError extends AppleError {
  const GrandSlamTwoFactorRequiredError(super.message);
}

/// [FetchTwoFactorCode] returned `null` - the user cancelled.
final class GrandSlamTwoFactorCancelledError extends AppleError {
  const GrandSlamTwoFactorCancelledError(super.message);
}

/// The code-validation endpoint returned `-21669`, an incorrect
/// verification code. Kept distinct from other [GrandSlamOperationError]s
/// so a caller can re-prompt instead of aborting.
final class GrandSlamIncorrectCodeError extends AppleError {
  const GrandSlamIncorrectCodeError(super.message);
}
