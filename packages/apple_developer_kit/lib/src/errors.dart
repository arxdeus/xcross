/// A user-facing error from Apple auth, provisioning, or codesigning.
class AppleError implements Exception {
  AppleError(this.message);

  final String message;

  @override
  String toString() => message;
}
