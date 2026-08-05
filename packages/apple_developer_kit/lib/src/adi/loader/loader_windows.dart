// Windows loader glue: wires the platform-independent ELF loader to a
// VirtualAlloc-backed allocator and Windows SysV-wrapped symbol stubs.

import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/src/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/adi/loader/loader.dart';
import 'package:apple_developer_kit/src/adi/loader/memory_allocator_windows.dart';
import 'package:apple_developer_kit/src/adi/loader/native_symbol_stubs_windows.dart';

class WindowsNativeLibraryLoader implements NativeLibraryLoader {
  WindowsNativeLibraryLoader() : _allocator = WindowsMemoryAllocator() {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'WindowsNativeLibraryLoader only runs on Windows.',
      );
    }
    if (Abi.current() != Abi.windowsX64) {
      throw UnsupportedError(
        'Windows ADI loader requires windows_x64 (got ${Abi.current()}).',
      );
    }
    _stubs = WindowsNativeSymbolStubs(loadLibraryForDlopen: _loadByPath);
  }

  final WindowsMemoryAllocator _allocator;
  late final WindowsNativeSymbolStubs _stubs;
  final Map<String, ElfLoadedLibrary> _loaded = {};
  String? _lastLoadDir;

  ElfLoadedLibrary _loadByPath(String path) {
    // Note the deliberate asymmetry, matching existing behaviour: the
    // cache is probed with the canonical path but populated with the
    // (possibly fallback-resolved) path actually read.
    final canonical = File(path).absolute.path;
    final cached = _loaded[canonical];
    if (cached != null) return cached;

    final resolvedPath = _resolvePath(path, canonical);
    final lib = ElfLoadedLibrary.load(
      File(resolvedPath).readAsBytesSync(),
      _allocator,
      _stubs.resolve,
    );
    _loaded[resolvedPath] = lib;
    return lib;
  }

  // Same bare-name sibling fallback as loader_posix.dart, including its
  // ponytail caveat: it is an addition not present upstream and has not
  // been verified against what the real libstoreservicescore.so requests.
  String _resolvePath(String requested, String canonical) {
    if (File(canonical).existsSync()) return canonical;

    final fallbackDir = _lastLoadDir;
    final isBareName = !requested.contains('/') && !requested.contains(r'\');
    if (fallbackDir == null || !isBareName) return canonical;

    final candidate = File('$fallbackDir${Platform.pathSeparator}$requested');
    return candidate.existsSync() ? candidate.absolute.path : canonical;
  }

  @override
  LoadedNativeLibrary load(String path) {
    _lastLoadDir = File(path).parent.path;
    return _WindowsLoadedLibrary(_loadByPath(path));
  }
}

class _WindowsLoadedLibrary implements LoadedNativeLibrary {
  _WindowsLoadedLibrary(this._lib);

  final ElfLoadedLibrary _lib;

  @override
  Pointer<NativeFunction<T>> lookup<T extends Function>(String symbolName) =>
      _lib.lookup(symbolName).cast();
}
