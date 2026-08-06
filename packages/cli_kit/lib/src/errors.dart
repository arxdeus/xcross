/// A user-facing error whose [message] is printed without a stack trace.
final class CliError implements Exception {
  CliError(this.message);

  final String message;

  @override
  String toString() => message;
}
