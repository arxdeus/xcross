import 'package:meta/meta.dart';

@internal
abstract interface class SwiftToolchainHostInterface {
  String get installGuidance;
  String? failureGuidance(int exitCode);
}
