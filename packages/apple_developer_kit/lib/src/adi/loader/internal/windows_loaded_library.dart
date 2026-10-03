import 'dart:ffi';

import 'package:apple_developer_kit/src/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/adi/loader/internal/sysv_abi_bridge.dart';
import 'package:apple_developer_kit/src/adi/loader/loader.dart';

final class WindowsLoadedLibrary implements LoadedNativeLibrary {
  WindowsLoadedLibrary(this._lib);

  final ElfLoadedLibrary _lib;

  @override
  Pointer<NativeFunction<T>> lookup<T extends Function>(String symbolName) =>
      _lib.lookup(symbolName).cast();

  @override
  Pointer<NativeFunction<T>> callable<T extends Function>(
    String symbolName,
    int argumentCount,
  ) => SysvAbiBridge.sysvImport(lookup<T>(symbolName), argumentCount);
}
