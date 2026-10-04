import 'dart:ffi';

import 'package:apple_developer_kit/src/host/linux/adi/linux_memory_allocator.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/loader_posix.dart';
import 'package:apple_developer_kit/src/shared/adi/adi_architecture.dart';

final class LinuxNativeLibraryLoader extends PosixNativeLibraryLoader {
  LinuxNativeLibraryLoader()
    : super(
        _createAllocator(),
        machine: AdiArchitecture.forAbi(Abi.current()).elfMachine,
      );
  static LinuxMemoryAllocator _createAllocator() => switch (Abi.current()) {
    Abi.linuxX64 || Abi.linuxArm64 => LinuxMemoryAllocator(),
    final abi => throw UnsupportedError(
      'Linux ADI loader does not support native ABI $abi.',
    ),
  };
}
