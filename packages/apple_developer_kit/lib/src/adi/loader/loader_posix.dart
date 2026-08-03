// POSIX loader glue: wires the platform-independent ELF loader
// (`../elf/elf_loaded_library.dart`) to a POSIX `mmap`/`mprotect`-backed
// memory allocator (`memory_allocator_posix.dart`) and the fixed symbol
// stub table (`native_symbol_stubs.dart`).
//
// This file previously wrapped `dart:ffi`'s `DynamicLibrary.open` (a
// plain `dlopen()`), which was actively unsafe: bionic's
// `pthread_mutex_t`/`pthread_once_t` are ~4 bytes, glibc's are ~40, and a
// real `dlopen()` resolves the loaded library's `pthread_*` imports to
// the real (wrongly-sized) glibc functions, corrupting adjacent memory
// the instant they're called. That path has been removed entirely — see
// NOTICE.md.

import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/src/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/adi/loader/loader.dart';
import 'package:apple_developer_kit/src/adi/loader/memory_allocator_posix.dart';
import 'package:apple_developer_kit/src/adi/loader/native_symbol_stubs.dart';

class PosixNativeLibraryLoader implements NativeLibraryLoader {
  PosixNativeLibraryLoader() : _allocator = PosixMemoryAllocator() {
    // Linux only for now — see native_symbol_stubs.dart's file-level
    // note. macOS needs compat/macos.d's open()/stat() flag and struct
    // translation ported first; without it, this loader would risk the
    // same class of silent-corruption bug on macOS (via stat/open this
    // time) that it exists to avoid on pthreads.
    if (!Platform.isLinux) {
      throw UnsupportedError(
        'provision_dart\'s native ELF loader currently only supports '
        'Linux. macOS needs lib/provision/compat/macos.d\'s open()/stat() '
        'translation ported first — see NOTICE.md.',
      );
    }
    _stubs = NativeSymbolStubs(loadLibraryForDlopen: _loadByPath);
  }

  final PosixMemoryAllocator _allocator;
  late final NativeSymbolStubs _stubs;
  final Map<String, ElfLoadedLibrary> _loaded = {};
  String? _lastLoadDir;

  ElfLoadedLibrary _loadByPath(String path) {
    final cached = _loaded[path];
    if (cached != null) return cached;

    var resolvedPath = path;
    if (!File(resolvedPath).existsSync()) {
      // ponytail: this fallback is an addition, NOT present upstream —
      // upstream's own dlopen emulation does a literal, unmodified open
      // of whatever string the loaded library passed
      // (symbols.d's dlopenWrapper -> `new AndroidLibrary(name)`, no
      // search path at all). If the requested name is a bare filename
      // (no directory separator) and isn't found as given, we also try
      // it next to the last explicitly-`load()`-ed path, on the
      // (UNVERIFIED) assumption that sibling libraries live in the same
      // directory. Whether the real `libstoreservicescore.so` actually
      // requests a bare filename or an already-fully-qualified path here
      // has not been confirmed against the real extracted library — see
      // NOTICE.md.
      final fallbackDir = _lastLoadDir;
      final isBareName = !path.contains('/') && !path.contains(r'$');
      if (fallbackDir != null && isBareName) {
        final candidate = File('$fallbackDir${Platform.pathSeparator}$path');
        if (candidate.existsSync()) resolvedPath = candidate.path;
      }
    }

    final lib = ElfLoadedLibrary.load(
      File(resolvedPath).readAsBytesSync(),
      _allocator,
      _stubs.resolve,
    );
    _loaded[path] = lib;
    return lib;
  }

  @override
  LoadedNativeLibrary load(String path) {
    _lastLoadDir = File(path).parent.path;
    return _PosixLoadedLibrary(_loadByPath(path));
  }
}

class _PosixLoadedLibrary implements LoadedNativeLibrary {
  _PosixLoadedLibrary(this._lib);

  final ElfLoadedLibrary _lib;

  @override
  Pointer<NativeFunction<T>> lookup<T extends Function>(String symbolName) =>
      _lib.lookup(symbolName).cast();
}
