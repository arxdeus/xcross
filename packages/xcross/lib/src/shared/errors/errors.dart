import 'package:meta/meta.dart';

/// A user-facing error. Its [message] is printed without a Dart stack trace.
@internal
final class XcrossError implements Exception {
  XcrossError(this.message);

  final String message;

  @override
  String toString() => message;
}
