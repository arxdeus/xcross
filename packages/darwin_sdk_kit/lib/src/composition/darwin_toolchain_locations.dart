import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/src/host/linux/linux_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/src/host/macos/macos_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/src/host/shared/darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/src/host/windows/windows_darwin_toolchain_locations.dart';

DarwinToolchainLocationsInterface darwinToolchainLocations(
  PlatformHostInterface host,
) => host.accept(const _LocationsVisitor());

final class _LocationsVisitor
    implements PlatformHostVisitor<DarwinToolchainLocationsInterface> {
  const _LocationsVisitor();
  @override
  DarwinToolchainLocationsInterface visitWindows(WindowsHostInterface host) =>
      WindowsDarwinToolchainLocations(host);
  @override
  DarwinToolchainLocationsInterface visitLinux(LinuxHostInterface host) =>
      LinuxDarwinToolchainLocations(host);
  @override
  DarwinToolchainLocationsInterface visitMacOS(MacOSHostInterface host) =>
      MacOSDarwinToolchainLocations(host);
}
