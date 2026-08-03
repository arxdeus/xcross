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
    final canonical = File(path).absolute.path;
    final cached = _loaded[canonical];
    if (cached != null) return cached;

    var resolvedPath = canonical;
    if (!File(resolvedPath).existsSync()) {
      // Same bare-name sibling fallback as loader_posix.dart.
      final fallbackDir = _lastLoadDir;
      final isBareName = !path.contains('/') && !path.contains(r'\');
      if (fallbackDir != null && isBareName) {
        final candidate = File('$fallbackDir${Platform.pathSeparator}$path');
        if (candidate.existsSync()) {
          resolvedPath = candidate.absolute.path;
        }
      }
    }

    final lib = ElfLoadedLibrary.load(
      File(resolvedPath).readAsBytesSync(),
      _allocator,
      _stubs.resolve,
    );
    _loaded[resolvedPath] = lib;
    return lib;
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
