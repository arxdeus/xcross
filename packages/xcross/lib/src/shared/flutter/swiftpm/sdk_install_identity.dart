import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';

final class SdkInstallSwiftPmIdentity<T extends PlatformHostInterface>
    implements SwiftPmSdkIdentity {
  const SdkInstallSwiftPmIdentity(
    this.install, {
    required this.platformIdentity,
  });
  final SdkInstall<T> install;
  @override
  final String platformIdentity;
  @override
  Future<Map<String, Object>> sdkBuildIdentity(String root) =>
      install.sdkBuildIdentity(root);
  @override
  Future<Map<String, Object>> hostToolchainIdentity() =>
      install.hostToolchainIdentity();
  @override
  Future<String?> hostToolchainMismatch(String root) =>
      install.hostToolchainMismatch(root);
  @override
  String mismatchGuidance(String? detail) =>
      SdkInstall.mismatchGuidance(detail);
  @override
  Future<Map<String, Object>> swiftPmBuildToolchainIdentity({
    required String cCompilerPath,
    required String cxxCompilerPath,
    required String linkerPath,
    required String librarianPath,
  }) => install.swiftPmBuildToolchainIdentity(
    cCompilerPath: cCompilerPath,
    cxxCompilerPath: cxxCompilerPath,
    linkerPath: linkerPath,
    librarianPath: librarianPath,
  );
}
