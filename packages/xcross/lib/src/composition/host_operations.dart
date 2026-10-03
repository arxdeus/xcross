import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/cli/basic/internal/swift_requirement.dart';
import 'package:xcross/src/host/linux/setup/linux_setup_requirements.dart';
import 'package:xcross/src/host/linux/update/linux_update_policy.dart';
import 'package:xcross/src/host/macos/setup/macos_setup_requirements.dart';
import 'package:xcross/src/host/macos/update/macos_update_policy.dart';
import 'package:xcross/src/host/shared/setup/posix_setup_script.dart';
import 'package:xcross/src/host/shared/update/posix_dart_launcher.dart';
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
) => SetupRequirementServices(
  host: host,
  runner: runner,
  toolchain: toolchain,
  privileges: privileges,
  resolvePipx: pymd.resolvePipx,
  ensurePymdInstalled: pymd.ensureInstalled,
);

HostOperations windowsHostOperations(
  WindowsHostInterface host,
  ProcessRunner runner,
  DarwinToolchainResolver toolchain,
  Pymd pymd,
  HostPrivilegesInterface privileges,
) => HostOperations(
  setupScript: WindowsSetupScript(host, runner),
  setupRequirements: WindowsSetupRequirements(
    _services(host, runner, toolchain, pymd, privileges),
  ),
  swiftInstallGuidance: SwiftRequirement.installHint('windows'),
  update: WindowsUpdatePolicy(host, privileges),
  normalizeExecutable: normalizeWindowsExecutableExtension,
  acceptDartLauncher: (path) => const {
    'dart.exe',
    'dart.bat',
    'dart.cmd',
  }.contains(host.paths.context.basename(path).toLowerCase()),
);

HostOperations linuxHostOperations(
  LinuxHostInterface host,
  ProcessRunner runner,
  DarwinToolchainResolver toolchain,
  Pymd pymd,
  HostPrivilegesInterface privileges,
) => HostOperations(
  setupScript: PosixSetupScript(host),
  setupRequirements: LinuxSetupRequirements(
    _services(host, runner, toolchain, pymd, privileges),
  ),
  swiftInstallGuidance: SwiftRequirement.installHint('linux'),
  update: LinuxUpdatePolicy(host, runner, privileges),
  normalizeExecutable: (path) => path,
  acceptDartLauncher: PosixDartLauncher().accept,
);

HostOperations macOSHostOperations(
  MacOSHostInterface host,
  ProcessRunner runner,
  DarwinToolchainResolver toolchain,
  Pymd pymd,
  HostPrivilegesInterface privileges,
) => HostOperations(
  setupScript: PosixSetupScript(host),
  setupRequirements: MacOSSetupRequirements(
    _services(host, runner, toolchain, pymd, privileges),
  ),
  swiftInstallGuidance: SwiftRequirement.installHint('macos'),
  update: MacOSUpdatePolicy(host, runner, privileges),
  normalizeExecutable: (path) => path,
  acceptDartLauncher: PosixDartLauncher().accept,
);
