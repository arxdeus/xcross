// Binds mmap/mprotect/munmap directly from the host's own libc (via
// `DynamicLibrary.process()`) to implement [NativeMemoryAllocator] on
// Linux/macOS.
//
// This calls the *host's* real memory-mapping primitives to reserve pages
// for a manually-loaded library's segments — it has nothing to do with
// resolving symbols *from* the foreign (bionic) library, which is what
// `native_symbol_stubs.dart` handles instead, and where the real
// glibc-vs-bionic ABI hazard this whole loader exists to avoid actually
// lives. See NOTICE.md.

import 'dart:ffi';
import 'dart:io';

import 'memory_allocator.dart';

const int _protNone = 0;
const int _protRead = 1;
const int _protWrite = 2;
const int _protExec = 4;

const int _mapPrivate = 0x02;
// MAP_ANONYMOUS/MAP_ANON: standard POSIX <sys/mman.h> values, which differ
// between Linux and macOS (Darwin) — well-documented platform constants,
// not Provision-specific.
const int _mapAnonymousLinux = 0x20;
const int _mapAnonymousMacos = 0x1000;

typedef _MmapNative = Pointer<Void> Function(
    Pointer<Void> addr, IntPtr length, Int32 prot, Int32 flags, Int32 fd, Int64 offset);
typedef _MmapDart = Pointer<Void> Function(
    Pointer<Void> addr, int length, int prot, int flags, int fd, int offset);

typedef _MprotectNative = Int32 Function(Pointer<Void> addr, IntPtr length, Int32 prot);
typedef _MprotectDart = int Function(Pointer<Void> addr, int length, int prot);

typedef _MunmapNative = Int32 Function(Pointer<Void> addr, IntPtr length);
typedef _MunmapDart = int Function(Pointer<Void> addr, int length);

class PosixMemoryAllocator implements NativeMemoryAllocator {
  PosixMemoryAllocator({bool? isMacos})
      : _isMacos = isMacos ?? Platform.isMacOS,
        _mmap = DynamicLibrary.process().lookupFunction<_MmapNative, _MmapDart>('mmap'),
        _mprotect =
            DynamicLibrary.process().lookupFunction<_MprotectNative, _MprotectDart>('mprotect'),
        _munmap = DynamicLibrary.process().lookupFunction<_MunmapNative, _MunmapDart>('munmap');

  final bool _isMacos;
  final _MmapDart _mmap;
  final _MprotectDart _mprotect;
  final _MunmapDart _munmap;

  @override
  NativeMemoryBlock alloc(int size) {
    final mapAnon = _isMacos ? _mapAnonymousMacos : _mapAnonymousLinux;
    final result = _mmap(
      nullptr,
      size,
      _protRead | _protWrite,
      _mapPrivate | mapAnon,
      -1,
      0,
    );
    if (result.address == 0 || result.address == -1) {
      throw StateError('mmap failed to reserve $size bytes.');
    }
    return NativeMemoryBlock(result.cast(), size);
  }

  @override
  void protect(
    NativeMemoryBlock block, {
    required int offset,
    required int length,
    required bool readable,
    required bool writable,
    required bool executable,
  }) {
    var prot = _protNone;
    if (readable) prot |= _protRead;
    if (writable) prot |= _protWrite;
    if (executable) prot |= _protExec;

    final address = (block.pointer + offset).cast<Void>();
    final result = _mprotect(address, length, prot);
    if (result != 0) {
      throw StateError('mprotect failed for offset=$offset length=$length.');
    }
  }

  @override
  void free(NativeMemoryBlock block) {
    _munmap(block.pointer.cast(), block.length);
  }
}
