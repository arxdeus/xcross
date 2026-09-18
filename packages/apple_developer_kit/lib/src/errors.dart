import 'package:meta/meta.dart';

/// A user-facing error from Apple auth, provisioning, or codesigning.
@immutable
base class AppleError implements Exception {
  const AppleError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Apple refused a request with HTTP 429. Authentication requests must not
/// be replayed automatically, especially requests that send a two-factor code.
final class AppleRateLimitError extends AppleError {
  AppleRateLimitError({required this.operation, this.retryAfter})
    : super(
        '$operation failed (HTTP 429 Too Many Requests). '
        '${retryAfter == null ? 'Apple did not provide a usable Retry-After. Wait before trying again.' : 'Wait at least ${retryAfter.inSeconds} seconds before trying again.'} '
        'The request was not retried. Repeated sign-in attempts can prolong '
        'throttling. Do not clear your Anisette state or reset your password '
        'to resolve this error.',
      );

  final String operation;
  final Duration? retryAfter;
}

/// Raised by a provisioning backend that cannot read or write App ID
/// capabilities (the legacy developerservices2 / Apple ID session client).
///
/// Provisioning treats it as "no capabilities known" and warns, rather than
/// failing a build over something the backend simply does not expose.
final class CapabilitiesUnsupported implements Exception {
  const CapabilitiesUnsupported();

  @override
  String toString() =>
      'This provisioning backend cannot manage App ID capabilities.';
}

/// The signing credentials in use cannot provision App Groups at all.
///
/// This is a property of Apple's APIs rather than a transient failure: an App
/// Store Connect API key has no way to create an App Group or attach one to an
/// App ID, and a profile issued without one grants an empty
/// `com.apple.security.application-groups` array that iOS refuses to accept a
/// real group against. See `AscClient.findAppGroup` for the full evidence.
///
/// Callers should treat it as "this credential type cannot do this", not as an
/// error to retry, and point the user at `xcross auth --apple-id`.
final class AppGroupsUnsupported extends AppleError {
  const AppGroupsUnsupported()
    : super(
        'App Groups cannot be provisioned with an App Store Connect API key: '
        'Apple exposes no App Groups resource to API keys, and a profile '
        'issued without a group grants an empty application-groups array that '
        'iOS rejects. Sign in with `xcross auth --apple-id <email>` to let an '
        'app and its extensions share data.',
      );
}
