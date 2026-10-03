import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/host/shared/config/posix_config_host.dart';
import 'package:xcross/src/host/windows/config/windows_config_host.dart';
import 'package:xcross/src/shared/config/config_host.dart';

ConfigHostInterface configHostPolicy(PlatformHostInterface host) =>
    host.accept(const _ConfigHostVisitor());

final class _ConfigHostVisitor
    implements PlatformHostVisitor<ConfigHostInterface> {
  const _ConfigHostVisitor();

  @override
  ConfigHostInterface visitLinux(LinuxHostInterface host) =>
      const PosixConfigHost();
  @override
  ConfigHostInterface visitMacOS(MacOSHostInterface host) =>
      const PosixConfigHost();
  @override
  ConfigHostInterface visitWindows(WindowsHostInterface host) =>
      const WindowsConfigHost();
}
