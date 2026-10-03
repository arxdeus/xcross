import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:apple_developer_kit/src/adi/loader/internal/memory_allocator.dart';
import 'package:apple_developer_kit/src/host/linux/adi/linux_memory_allocator.dart';
import 'package:apple_developer_kit/src/host/macos/adi/macos_memory_allocator.dart';
import 'package:cli_kit/cli_kit.dart';

AppleHostServices get testHostServices {
  if (Platform.isWindows) {
    return testWindowsAppleHostServices(
      WindowsHost(currentDirectory: Directory.current.path),
      localeName: 'en_US',
      abi: Abi.current(),
    );
  }
  if (Platform.isMacOS) {
    return testMacOSAppleHostServices(
      MacOSHost(currentDirectory: Directory.current.path),
      localeName: 'en_US',
      abi: Abi.current(),
    );
  }
  return createLinuxAppleHostServices(
    LinuxHost(currentDirectory: Directory.current.path),
    localeName: 'en_US',
    abi: Abi.current(),
  );
}

NativeLibraryLoader testNativeLoader() {
  if (Platform.isWindows) return createWindowsNativeLibraryLoader();
  if (Platform.isMacOS) return createMacOSNativeLibraryLoader();
  return createLinuxNativeLibraryLoader();
}

NativeMemoryAllocator testPosixAllocator() =>
    Platform.isMacOS ? MacOSMemoryAllocator() : LinuxMemoryAllocator();

final class UnusedNativeLoader implements NativeLibraryLoader {
  @override
  LoadedNativeLibrary load(String path) =>
      throw StateError('Unexpected native library access: $path');
}

AppleHostServices testMacOSAppleHostServices(
  MacOSHostInterface host, {
  required String localeName,
  required Abi abi,
}) => createMacOSAppleHostServices(
  host,
  runner: ProcessRunner(host, log: Log(output: SilentLogOutput())),
  localeName: localeName,
  abi: abi,
);
AppleHostServices testWindowsAppleHostServices(
  WindowsHostInterface host, {
  required String localeName,
  required Abi abi,
}) => createWindowsAppleHostServices(
  host,
  runner: ProcessRunner(host, log: Log(output: SilentLogOutput())),
  localeName: localeName,
  abi: abi,
);

final class SilentLogOutput implements LogOutput {
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) {}
  @override
  void stderr(String message) {}
  @override
  void write(String message) {}
}
