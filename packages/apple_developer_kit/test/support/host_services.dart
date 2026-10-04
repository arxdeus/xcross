import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/composition/apple_host.dart';
import 'package:apple_developer_kit/composition/native_library_loader.dart';
import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/host/linux/adi/linux_memory_allocator.dart';
import 'package:apple_developer_kit/src/host/macos/adi/macos_memory_allocator.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/memory_allocator.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';

@internal
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

@internal
NativeLibraryLoader testNativeLoader() {
  if (Platform.isWindows) return createWindowsNativeLibraryLoader();
  if (Platform.isMacOS) return createMacOSNativeLibraryLoader();
  return createLinuxNativeLibraryLoader();
}

@internal
NativeMemoryAllocator testPosixAllocator() =>
    Platform.isMacOS ? MacOSMemoryAllocator() : LinuxMemoryAllocator();

@internal
final class UnusedNativeLoader implements NativeLibraryLoader {
  @override
  LoadedNativeLibrary load(String path) =>
      throw StateError('Unexpected native library access: $path');
}

@internal
AppleHostServices testMacOSAppleHostServices(
  MacOSHostInterface host, {
  required String localeName,
  required Abi abi,
}) => createMacOSAppleHostServices(
  host,
  runner: ProcessRunner(
    host,
    log: Log(output: SilentLogOutput()),
    stdinStream: const Stream<List<int>>.empty(),
    stdoutSink: stdout,
    stderrSink: stderr,
  ),
  localeName: localeName,
  abi: abi,
);
@internal
AppleHostServices testWindowsAppleHostServices(
  WindowsHostInterface host, {
  required String localeName,
  required Abi abi,
}) => createWindowsAppleHostServices(
  host,
  runner: ProcessRunner(
    host,
    log: Log(output: SilentLogOutput()),
    stdinStream: const Stream<List<int>>.empty(),
    stdoutSink: stdout,
    stderrSink: stderr,
  ),
  localeName: localeName,
  abi: abi,
);

@internal
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
