import 'dart:ffi';

/// Strategy for loading a native shared library from a filesystem path.
///
/// Unlike a plain `dlopen` wrapper, this does NOT hand back an SDK
/// [DynamicLibrary] — see NOTICE.md for why a plain `dlopen()` is
/// actively unsafe for the specific libraries this package loads (it can
/// silently corrupt memory rather than fail cleanly). Implementations
/// instead return a [LoadedNativeLibrary] backed by this package's own
/// manually-relocated ELF loader (`../elf/elf_loaded_library.dart`).
abstract class NativeLibraryLoader {
  /// Loads the native library at [path].
  LoadedNativeLibrary load(String path);
}

/// A loaded native library, capable of resolving exported symbols to
/// callable native function pointers.
abstract class LoadedNativeLibrary {
  /// Resolves [symbolName] to a callable native function pointer of type
  /// [T].
  Pointer<NativeFunction<T>> lookup<T extends Function>(String symbolName);
}
