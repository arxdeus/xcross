import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/composition/apple_host.dart';
import 'package:apple_developer_kit/composition/native_library_loader.dart';
import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/host/linux/adi/linux_memory_allocator.dart';
import 'package:apple_developer_kit/src/host/macos/adi/macos_memory_allocator.dart';
import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/memory_allocator.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:ffi/ffi.dart';
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

@internal
final class InertElfLibrary implements ElfLoadedLibrary {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected ELF access: ${invocation.memberName}');
}

@internal
final class RecordingPathLibrary
    implements NativeLibraryLoader, LoadedNativeLibrary {
  RecordingPathLibrary(this.adapter) {
    _pathCallback = NativeCallable<Int32 Function(Pointer<Utf8>)>.isolateLocal((
      Pointer<Utf8> path,
    ) {
      pathBytes.add(List<int>.of(path.cast<Uint8>().asTypedList(path.length)));
      return 0;
    }, exceptionalReturn: -1);
    _identifierCallback =
        NativeCallable<Int32 Function(Pointer<Uint8>, Uint32)>.isolateLocal(
          (Pointer<Uint8> identifier, int length) => -1,
          exceptionalReturn: -1,
        );
  }

  final LoadedNativeLibrary adapter;
  final List<String> loadedPaths = [];
  final List<List<int>> pathBytes = [];
  late final NativeCallable<Int32 Function(Pointer<Utf8>)> _pathCallback;
  late final NativeCallable<Int32 Function(Pointer<Uint8>, Uint32)>
  _identifierCallback;

  void close() {
    _pathCallback.close();
    _identifierCallback.close();
  }

  @override
  LoadedNativeLibrary load(String path) {
    loadedPaths.add(path);
    return this;
  }

  @override
  String normalizePath(String path) => adapter.normalizePath(path);

  @override
  Pointer<NativeFunction<T>> callable<T extends Function>(
    String symbolName,
    int argumentCount,
  ) => switch (symbolName) {
    'kq56gsgHG6' || 'nf92ngaK92' => _pathCallback.nativeFunction.cast(),
    'Sph98paBcz' => _identifierCallback.nativeFunction.cast(),
    'p435tmhbla' ||
    'tn46gtiuhw' ||
    'fy34trz2st' ||
    'uv5t6nhkui' ||
    'rsegvyrt87' ||
    'aslgmuibau' ||
    'jk24uiwqrg' ||
    'qi864985u0' => Pointer.fromAddress(1),
    _ => throw StateError('Unexpected symbol: $symbolName'),
  };

  @override
  Pointer<NativeFunction<T>> lookup<T extends Function>(String symbolName) =>
      throw StateError('Unexpected raw symbol lookup: $symbolName');
}
