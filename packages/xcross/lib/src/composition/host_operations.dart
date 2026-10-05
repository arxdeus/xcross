import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/linux/sdk/linux_swift_toolchain_host.dart';
import 'package:xcross/src/host/linux/setup/linux_setup_requirements.dart';
import 'package:xcross/src/host/linux/update/linux_update_policy.dart';
import 'package:xcross/src/host/macos/sdk/macos_swift_toolchain_host.dart';
import 'package:xcross/src/host/macos/setup/macos_setup_requirements.dart';
import 'package:xcross/src/host/macos/update/macos_update_policy.dart';
import 'package:xcross/src/host/shared/sdk/inherited_swift_environment.dart';
import 'package:xcross/src/host/shared/setup/posix_setup_script.dart';
import 'package:xcross/src/host/shared/update/posix_dart_launcher.dart';
import 'package:xcross/src/host/windows/sdk/windows_swift_environment.dart';
import 'package:xcross/src/host/windows/sdk/windows_swift_toolchain_host.dart';
import 'package:xcross/src/host/windows/setup/windows_setup_requirements.dart';
import 'package:xcross/src/host/windows/setup/windows_setup_script.dart';
import 'package:xcross/src/host/windows/update/windows_update_policy.dart';
import 'package:xcross/src/host/windows/xcrun/windows_executable.dart';
import 'package:xcross/src/shared/setup/host_operations.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';

SetupRequirementServices _services(
  PlatformHostInterface host,
  ProcessRunner runner,
  DarwinToolchainResolver toolchain,
  Pymd pymd,
  HostPrivilegesInterface privileges,
  SetupConsole console,
) => SetupRequirementServices(
  host: host,
  runner: runner,
  toolchain: toolchain,
  privileges: privileges,
  console: console,
  resolvePipx: pymd.resolvePipx,
  ensurePymdInstalled: pymd.ensureInstalled,
);

@internal
HostOperations windowsHostOperations(
  WindowsHostInterface host,
  ProcessRunner runner,
  DarwinToolchainResolver toolchain,
  Pymd pymd,
  HostPrivilegesInterface privileges,
  SetupConsole console,
) {
  const executable = WindowsExecutable();
  return HostOperations(
    setupScript: WindowsSetupScript(host, runner),
    setupRequirements: WindowsSetupRequirements(
      _services(host, runner, toolchain, pymd, privileges, console),
    ),
    swiftToolchain: const WindowsSwiftToolchainHost(),
    swiftEnvironment: WindowsSwiftEnvironment(runner),
    update: WindowsUpdatePolicy(host, privileges),
    normalizeExecutable: executable.normalize,
    acceptDartLauncher: executable.acceptDartLauncher,
  );
}

@internal
HostOperations linuxHostOperations(
  LinuxHostInterface host,
  ProcessRunner runner,
  DarwinToolchainResolver toolchain,
  Pymd pymd,
  HostPrivilegesInterface privileges,
  SetupConsole console,
) {
  final launcher = PosixDartLauncher();
  return HostOperations(
    setupScript: PosixSetupScript(host),
    setupRequirements: LinuxSetupRequirements(
      _services(host, runner, toolchain, pymd, privileges, console),
    ),
    swiftToolchain: const LinuxSwiftToolchainHost(),
    swiftEnvironment: const InheritedSwiftEnvironment(),
    update: LinuxUpdatePolicy(host, runner, privileges),
    normalizeExecutable: launcher.normalizeExecutable,
    acceptDartLauncher: launcher.accept,
  );
}

@internal
HostOperations macOSHostOperations(
  MacOSHostInterface host,
  ProcessRunner runner,
  DarwinToolchainResolver toolchain,
  Pymd pymd,
  HostPrivilegesInterface privileges,
  SetupConsole console,
) {
  final launcher = PosixDartLauncher();
  return HostOperations(
    setupScript: PosixSetupScript(host),
    setupRequirements: MacOSSetupRequirements(
      _services(host, runner, toolchain, pymd, privileges, console),
    ),
    swiftToolchain: const MacOSSwiftToolchainHost(),
    swiftEnvironment: const InheritedSwiftEnvironment(),
    update: MacOSUpdatePolicy(host, runner, privileges),
    normalizeExecutable: launcher.normalizeExecutable,
    acceptDartLauncher: launcher.accept,
  );
}
