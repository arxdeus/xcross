// TODO(windows): Windows cannot `LoadLibrary` a Linux ELF `.so` at all —
// unlike the POSIX loader's original (now-removed) `dlopen` mistake,
// this isn't a "works but unsafe" case, it fails outright, since the
// Windows PE loader doesn't understand the ELF format. A real Windows
// implementation needs the SAME manually-relocated ELF loading strategy
// as `loader_posix.dart` — `../elf/elf_loaded_library.dart` is already
// platform-independent and can be reused as-is — just with a
// VirtualAlloc/VirtualProtect-backed `NativeMemoryAllocator`
// implementation instead of the POSIX mmap/mprotect one, plus a Windows
// port of `native_symbol_stubs.dart`'s libc/pthread stub table (Windows
// has no bionic-vs-glibc pthread hazard, but the loaded library's other
// bionic libc imports would still need equivalent stubs). Not
// implemented — out of scope for this phase.

import 'loader.dart';

class WindowsNativeLibraryLoader implements NativeLibraryLoader {
  const WindowsNativeLibraryLoader();

  @override
  LoadedNativeLibrary load(String path) {
    throw UnsupportedError(
      'provision_dart has no Windows native-library loader yet. See '
      'loader_windows.dart for what a real implementation needs.',
    );
  }
}
