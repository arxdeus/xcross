// Windows loader glue: wires the platform-independent ELF loader to a
// VirtualAlloc-backed allocator and Windows SysV-wrapped symbol stubs.

import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/memory_allocator_windows.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/native_symbol_stubs_windows.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows/windows_adi_abi.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/windows_loaded_library.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

@internal
final class WindowsNativeLibraryLoader implements NativeLibraryLoader {
  WindowsNativeLibraryLoader() : _abi = WindowsAdiAbi.forAbi(Abi.current());

  final WindowsAdiAbi _abi;
  late final WindowsMemoryAllocator _allocator = WindowsMemoryAllocator();
  late final WindowsNativeSymbolStubs _stubs = WindowsNativeSymbolStubs(
    abi: _abi,
    loadLibraryForDlopen: _loadByPath,
  );
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
    final bytes = File(resolvedPath).readAsBytesSync();
    _abi.validateElf(bytes);
    final lib = ElfLoadedLibrary.load(
      bytes,
      _allocator,
      _stubs.resolve,
      machine: _abi.architecture.elfMachine,
      codePreparation: _abi.codePreparation,
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

    final candidate = File(p.windows.join(fallbackDir, requested));
    return candidate.existsSync() ? candidate.absolute.path : canonical;
  }

  @override
  LoadedNativeLibrary load(String path) {
    _lastLoadDir = File(path).parent.path;
    return WindowsLoadedLibrary(_loadByPath(path));
  }
}
