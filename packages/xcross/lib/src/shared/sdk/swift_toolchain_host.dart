import 'package:meta/meta.dart';

@internal
abstract interface class SwiftToolchainHostInterface {
  String get installGuidance;
  (int, int)? get minimumSwift;
  String? failureGuidance(int exitCode);
}
