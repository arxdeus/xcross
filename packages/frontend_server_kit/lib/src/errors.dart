/// A user-facing error from the frontend_server session driver.
class FrontendServerException implements Exception {
  FrontendServerException(this.message);

  final String message;

  @override
  String toString() => message;
}
