/// A user-facing error from the frontend_server session driver.
final class FrontendServerException implements Exception {
  FrontendServerException(
    this.message, {
    this.errorCount,
    this.compilationFailed = false,
  });

  final String message;
  final int? errorCount;
  final bool compilationFailed;

  @override
  String toString() => message;
}
