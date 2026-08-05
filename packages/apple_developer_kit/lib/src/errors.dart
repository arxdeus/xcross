import 'package:meta/meta.dart';

/// A user-facing error from Apple auth, provisioning, or codesigning.
@immutable
class AppleError implements Exception {
  const AppleError(this.message);

  final String message;

  @override
  String toString() => message;
}
