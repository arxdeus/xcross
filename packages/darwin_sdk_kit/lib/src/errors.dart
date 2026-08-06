/// A user-facing error from Darwin/iOS SDK resolution or Xcode.xip extraction.
final class DarwinSdkError implements Exception {
  DarwinSdkError(this.message);

  final String message;

  @override
  String toString() => message;
}
