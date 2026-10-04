import 'package:meta/meta.dart';

@internal
abstract interface class SwiftPmSdkIdentity {
  Future<Map<String, Object>> sdkBuildIdentity(String sdkRoot);
  Future<String?> hostToolchainMismatch(String sdkRoot);
  String mismatchGuidance(String? detail);
  Future<Map<String, Object>> swiftPmBuildToolchainIdentity({
    required String cCompilerPath,
    required String cxxCompilerPath,
    required String linkerPath,
    required String librarianPath,
  });
  Future<Map<String, Object>> hostToolchainIdentity();
  String get platformIdentity;
}
