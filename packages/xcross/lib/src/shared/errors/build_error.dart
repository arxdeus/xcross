import 'package:meta/meta.dart';

/// A user-facing build failure. Its [message] is printed without a Dart stack
/// trace.
///
/// Feature-specific failures (Flutter packing, SwiftPM builds) extend this so
/// callers that only need the message or the security classification can
/// handle them uniformly.
@internal
abstract base class XcrossBuildError implements Exception {
  XcrossBuildError(this.message, {this.isSecurityFailure = false});

  final String message;
  final bool isSecurityFailure;

  @override
  String toString() => message;
}
