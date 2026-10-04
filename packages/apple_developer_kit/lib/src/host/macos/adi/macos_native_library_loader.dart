import 'dart:ffi';

import 'package:apple_developer_kit/src/host/macos/adi/macos_memory_allocator.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/loader_posix.dart';
import 'package:apple_developer_kit/src/shared/adi/adi_architecture.dart';
import 'package:meta/meta.dart';

@internal
final class MacOSNativeLibraryLoader extends PosixNativeLibraryLoader {
  MacOSNativeLibraryLoader()
    : super(
        _createAllocator(),
        machine: AdiArchitecture.forAbi(Abi.current()).elfMachine,
      );
  static MacOSMemoryAllocator _createAllocator() => switch (Abi.current()) {
    Abi.macosX64 || Abi.macosArm64 => MacOSMemoryAllocator(),
    final abi => throw UnsupportedError(
      'MacOS ADI loader does not support native ABI $abi.',
    ),
  };
}
