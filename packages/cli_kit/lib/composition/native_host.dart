import 'dart:ffi';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';

final class NativeHostSnapshot {
  const NativeHostSnapshot({
    required this.host,
    required this.abi,
    required this.resolvedExecutable,
    required this.localHostname,
    required this.localeName,
    required this.processorCount,
  });
  final PlatformHostInterface host;
  final Abi abi;
  final String resolvedExecutable;
  final String localHostname;
  final String localeName;
  final int processorCount;
}

PlatformHostInterface detectPlatformHost() => detectPlatformHostSnapshot().host;

NativeHostSnapshot detectPlatformHostSnapshot() {
  final environment = Platform.environment;
  final current = Directory.current.path;
  final temporary = Directory.systemTemp.path;
  final abi = Abi.current();
  final resolvedExecutable = Platform.resolvedExecutable;
  final localHostname = Platform.localHostname;
  final localeName = Platform.localeName;
  final processorCount = Platform.numberOfProcessors;
  final architecture = switch (abi) {
    Abi.windowsArm64 || Abi.linuxArm64 || Abi.macosArm64 => 'arm64',
    Abi.windowsX64 || Abi.linuxX64 || Abi.macosX64 => 'x64',
    Abi.windowsIA32 || Abi.linuxIA32 => 'x86',
    Abi.linuxArm => 'arm',
    _ => 'unknown',
  };
  if (Platform.isWindows) {
    return NativeHostSnapshot(
      host: WindowsHost(
        environment: environment,
        architecture: architecture,
        currentDirectory: current,
        temporaryDirectory: temporary,
      ),
      abi: abi,
      resolvedExecutable: resolvedExecutable,
      localHostname: localHostname,
      localeName: localeName,
      processorCount: processorCount,
    );
  }
  if (Platform.isLinux) {
    return NativeHostSnapshot(
      host: LinuxHost(
        environment: environment,
        architecture: architecture,
        currentDirectory: current,
        temporaryDirectory: temporary,
      ),
      abi: abi,
      resolvedExecutable: resolvedExecutable,
      localHostname: localHostname,
      localeName: localeName,
      processorCount: processorCount,
    );
  }
  if (Platform.isMacOS) {
    return NativeHostSnapshot(
      host: MacOSHost(
        environment: environment,
        architecture: architecture,
        currentDirectory: current,
        temporaryDirectory: temporary,
      ),
      abi: abi,
      resolvedExecutable: resolvedExecutable,
      localHostname: localHostname,
      localeName: localeName,
      processorCount: processorCount,
    );
  }
  throw UnsupportedError('Unsupported host: ${Platform.operatingSystem}');
}
