import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/host/shared/darwin_toolchain_locations.dart';

final class WindowsDarwinToolchainLocations
    implements DarwinToolchainLocationsInterface {
  const WindowsDarwinToolchainLocations(this.host);
  final WindowsHostInterface host;
  @override
  List<String> llvmToolDirectories() {
    const roots = {
      'ProgramFiles': 'LLVM',
      'ProgramW6432': 'LLVM',
      'ProgramFiles(x86)': 'LLVM',
      'LOCALAPPDATA': r'Programs\LLVM',
    };
    return [
      for (final root in roots.entries)
        if ((host.environment.lookup(host.environment.values, root.key) ?? '')
            .isNotEmpty)
          host.paths.context.join(
            host.environment.lookup(host.environment.values, root.key)!,
            root.value,
            'bin',
          ),
    ];
  }

  @override
  String get linkerInstallationHint =>
      "The Swift toolchain's own ld64.lld cannot link Mach-O for iOS. Install stock LLVM with `winget install --id LLVM.LLVM --exact` and add its bin directory to PATH.";
  @override
  String get clangInstallationHint =>
      'Install stock LLVM with `winget install --id LLVM.LLVM --exact` and add its bin directory to PATH.';
}
