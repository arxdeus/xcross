/// A user-facing error from Flutter iOS packing or hot reload.
final class FlutterBuildError implements Exception {
  FlutterBuildError(this.message, {this.isSecurityFailure = false});

  final String message;
  final bool isSecurityFailure;

  @override
  String toString() => message;
}
