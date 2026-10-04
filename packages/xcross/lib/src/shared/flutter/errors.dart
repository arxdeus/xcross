import 'package:meta/meta.dart';

/// A user-facing error from Flutter iOS packing or hot reload.
@internal
final class FlutterBuildError implements Exception {
  FlutterBuildError(this.message, {this.isSecurityFailure = false});

  final String message;
  final bool isSecurityFailure;

  @override
  String toString() => message;
}
