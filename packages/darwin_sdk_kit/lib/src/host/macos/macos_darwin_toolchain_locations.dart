import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/src/host/shared/darwin_toolchain_locations.dart';

final class MacOSDarwinToolchainLocations
    implements DarwinToolchainLocationsInterface {
  const MacOSDarwinToolchainLocations(this.host);
  final MacOSHostInterface host;
  @override
  List<String> llvmToolDirectories() => const [
    '/opt/homebrew/opt/lld/bin',
    '/opt/homebrew/opt/llvm/bin',
    '/usr/local/opt/lld/bin',
    '/usr/local/opt/llvm/bin',
  ];
  @override
  String get linkerInstallationHint =>
      'Install LLVM with `brew install lld && brew install llvm`, or `xcross setup`, and put it on PATH.';
  @override
  String get clangInstallationHint =>
      'Install LLVM with `brew install llvm`, or `xcross setup`, and put it on PATH.';
}
