import 'dart:ffi';
import 'package:apple_developer_kit/src/host/linux/linux_machine_identity.dart';
import 'package:apple_developer_kit/src/host/macos/macos_machine_identity.dart';
import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/host/shared/posix_file_permissions.dart';
import 'package:apple_developer_kit/src/host/windows/windows_file_permissions.dart';
import 'package:apple_developer_kit/src/host/windows/windows_machine_identity.dart';
import 'package:cli_kit/cli_kit.dart';

AppleHostServices createLinuxAppleHostServices(
  LinuxHostInterface host, {
  required String localeName,
  required Abi abi,
}) => AppleHostServices(
  host: host,
  abi: abi,
  localeName: localeName,
  machineIdentity: LinuxMachineIdentity(host.fileSystem),
  permissions: const PosixAppleFilePermissions(),
);

AppleHostServices createMacOSAppleHostServices(
  MacOSHostInterface host, {
  required ProcessRunner<MacOSHostInterface> runner,
  required String localeName,
  required Abi abi,
}) => AppleHostServices(
  host: host,
  abi: abi,
  localeName: localeName,
  machineIdentity: MacOSMachineIdentity(runner.run),
  permissions: const PosixAppleFilePermissions(),
);

AppleHostServices createWindowsAppleHostServices(
  WindowsHostInterface host, {
  required ProcessRunner<WindowsHostInterface> runner,
  required String localeName,
  required Abi abi,
}) => AppleHostServices(
  host: host,
  abi: abi,
  localeName: localeName,
  machineIdentity: WindowsMachineIdentity(runner.run, runner.locateTool),
  permissions: const WindowsAppleFilePermissions(),
);
