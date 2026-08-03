/// A user-facing error from Flutter iOS packing or hot reload.
class FlutterBuildError implements Exception {
  FlutterBuildError(this.message);

  final String message;

  @override
  String toString() => message;
}
