/// A user-facing error. Its [message] is printed without a Dart stack trace.
class CliError implements Exception {
  CliError(this.message);

  final String message;

  @override
  String toString() => message;
}
