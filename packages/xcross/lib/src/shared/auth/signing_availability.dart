import 'dart:async';
import 'dart:io';

import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/auth/signing_session.dart';

/// Apple's provisioning services cannot be used right now, but nothing is
/// wrong with the saved credentials themselves.
///
/// Raised when the network is down (or Apple is), when the saved Apple ID
/// session has expired, or when the user asked for offline mode. The device
/// backend answers it by signing with the certificate and profile cached by an
/// earlier online run; [message] is what the user sees when no such cache
/// exists.
@internal
final class SigningServiceUnavailable implements Exception {
  SigningServiceUnavailable({
    required this.reason,
    required this.message,
    required this.identity,
  });

  /// The connectivity failure [cause], phrased for the user.
  factory SigningServiceUnavailable.unreachable(
    Object cause, {
    required SigningIdentity? identity,
  }) {
    final reason = 'Apple Developer services are unreachable ($cause)';
    return SigningServiceUnavailable(
      reason: reason,
      message: '$reason.',
      identity: identity,
    );
  }

  /// The account whose cached signing material may be used instead, when
  /// one is known.
  final SigningIdentity? identity;

  /// One short clause, shown in the "signing offline" warning.
  final String reason;

  /// The full error to report when there is nothing cached to fall back on.
  final String message;

  @override
  String toString() => message;

  /// Whether [error] means "could not talk to Apple" rather than "Apple said
  /// no". Only the former may fall back to cached signing material: a 401 or
  /// a revoked certificate must surface, not be papered over.
  @useResult
  static bool isConnectivityFailure(Object error) => switch (error) {
    SocketException() ||
    http.ClientException() ||
    TlsException() ||
    HttpException() ||
    TimeoutException() => true,
    AppleApiError(:final statusCode) => statusCode >= 500,
    _ => false,
  };
}
