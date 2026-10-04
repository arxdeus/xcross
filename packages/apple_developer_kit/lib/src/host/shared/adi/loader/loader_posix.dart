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

import 'dart:io';

import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/memory_allocator.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/native_symbol_stubs.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/posix_loaded_library.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/loader.dart';

abstract class PosixNativeLibraryLoader implements NativeLibraryLoader {
  PosixNativeLibraryLoader(this._allocator, {required int machine})
    : _machine = machine {
    _stubs = NativeSymbolStubs(loadLibraryForDlopen: _loadByPath);
  }

  final int _machine;
  final NativeMemoryAllocator _allocator;
  late final NativeSymbolStubs _stubs;
  final Map<String, ElfLoadedLibrary> _loaded = {};
  String? _lastLoadDir;

  ElfLoadedLibrary _loadByPath(String path) {
    final cached = _loaded[path];
    if (cached != null) return cached;

    final lib = ElfLoadedLibrary.load(
      File(_resolvePath(path)).readAsBytesSync(),
      _allocator,
      _stubs.resolve,
      machine: _machine,
    );
    _loaded[path] = lib;
    return lib;
  }

  // ponytail: this fallback is an addition, NOT present upstream —
  // upstream's own dlopen emulation does a literal, unmodified open of
  // whatever string the loaded library passed (symbols.d's dlopenWrapper
  // -> `new AndroidLibrary(name)`, no search path at all). If the
  // requested name is a bare filename (no directory separator) and isn't
  // found as given, we also try it next to the last
  // explicitly-`load()`-ed path, on the (UNVERIFIED) assumption that
  // sibling libraries live in the same directory. Whether the real
  // `libstoreservicescore.so` actually requests a bare filename or an
  // already-fully-qualified path here has not been confirmed against the
  // real extracted library — see NOTICE.md.
  String _resolvePath(String path) {
    if (File(path).existsSync()) return path;

    final fallbackDir = _lastLoadDir;
    final isBareName = !path.contains('/') && !path.contains(r'$');
    if (fallbackDir == null || !isBareName) return path;

    final candidate = File('$fallbackDir/$path');
    return candidate.existsSync() ? candidate.path : path;
  }

  @override
  LoadedNativeLibrary load(String path) {
    _lastLoadDir = File(path).parent.path;
    return PosixLoadedLibrary(_loadByPath(path));
  }
}
