import 'dart:ffi';

/// A block of native memory allocated by a [NativeMemoryAllocator].
class NativeMemoryBlock {
  const NativeMemoryBlock(this.pointer, this.length);

  final Pointer<Uint8> pointer;
  final int length;
}

/// Low-level anonymous-memory allocator used by `ElfLoadedLibrary`
/// (`../elf/elf_loaded_library.dart`) to reserve and protect the pages it
/// manually maps ELF `PT_LOAD` segments into.
///
/// This is unrelated to the host-vs-bionic symbol problem this loader
/// exists to avoid (see NOTICE.md): it's just asking the *host* OS for a
/// block of RAM to copy segments into, the same primitive every ELF
/// loader (including the OS's own) uses — not resolving symbols *from*
/// the foreign library, which `NativeSymbolStubs`
/// (`native_symbol_stubs.dart`) handles instead.
abstract class NativeMemoryAllocator {
  /// Reserves an anonymous block of [size] bytes.
  NativeMemoryBlock alloc(int size);

  /// Changes protection of [block]'s `[offset, offset + length)` byte
  /// range. Both must be page-aligned (the caller, `ElfLoadedLibrary`,
  /// takes care of that).
  void protect(
    NativeMemoryBlock block, {
    required int offset,
    required int length,
    required bool readable,
    required bool writable,
    required bool executable,
  });

  /// Releases a block previously returned by [alloc].
  void free(NativeMemoryBlock block);
}
