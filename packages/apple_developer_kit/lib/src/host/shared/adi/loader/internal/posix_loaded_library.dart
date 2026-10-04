import 'dart:ffi';

import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/loader.dart';

final class PosixLoadedLibrary implements LoadedNativeLibrary {
  PosixLoadedLibrary(this._lib);

  final ElfLoadedLibrary _lib;

  @override
  Pointer<NativeFunction<T>> lookup<T extends Function>(String symbolName) =>
      _lib.lookup(symbolName).cast();

  @override
  Pointer<NativeFunction<T>> callable<T extends Function>(
    String symbolName,
    int argumentCount,
  ) => lookup<T>(symbolName);
}
