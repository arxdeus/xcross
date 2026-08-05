// Windows VirtualAlloc/VirtualProtect/VirtualFree-backed
// [NativeMemoryAllocator], mirroring PosixMemoryAllocator's role for the
// manual ELF loader. Protection flags follow Provision's
// `compat/windows.d` `protectionToWindows` mapping.

import 'dart:ffi';

import 'package:apple_developer_kit/src/adi/loader/memory_allocator.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

const int _memCommit = 0x0000_1000;
const int _memReserve = 0x0000_2000;
const int _memRelease = 0x0000_8000;

const int _pageNoaccess = 0x01;
const int _pageReadonly = 0x02;
const int _pageReadwrite = 0x04;
const int _pageExecute = 0x10;
const int _pageExecuteRead = 0x20;
const int _pageExecuteReadwrite = 0x40;

typedef _VirtualAllocDart =
    Pointer<Void> Function(
      Pointer<Void> address,
      int size,
      int allocationType,
      int protect,
    );

typedef _VirtualProtectDart =
    int Function(
      Pointer<Void> address,
      int size,
      int newProtect,
      Pointer<Uint32> oldProtect,
    );

typedef _VirtualFreeDart =
    int Function(Pointer<Void> address, int size, int freeType);

@internal
class WindowsMemoryAllocator implements NativeMemoryAllocator {
  WindowsMemoryAllocator()
    : _virtualAlloc = DynamicLibrary.process()
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>, IntPtr, Uint32, Uint32),
            _VirtualAllocDart
          >('VirtualAlloc'),
      _virtualProtect = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Void>, IntPtr, Uint32, Pointer<Uint32>),
            _VirtualProtectDart
          >('VirtualProtect'),
      _virtualFree = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Void>, IntPtr, Uint32),
            _VirtualFreeDart
          >('VirtualFree');

  final _VirtualAllocDart _virtualAlloc;
  final _VirtualProtectDart _virtualProtect;
  final _VirtualFreeDart _virtualFree;

  @override
  NativeMemoryBlock alloc(int size) {
    final result = _virtualAlloc(
      nullptr,
      size,
      _memCommit | _memReserve,
      _pageReadwrite,
    );
    if (result == nullptr) {
      throw StateError('VirtualAlloc failed to reserve $size bytes.');
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
    final address = (block.pointer + offset).cast<Void>();
    final oldProtect = calloc<Uint32>();
    try {
      final result = _virtualProtect(
        address,
        length,
        _protection(
          readable: readable,
          writable: writable,
          executable: executable,
        ),
        oldProtect,
      );
      if (result == 0) {
        throw StateError(
          'VirtualProtect failed for offset=$offset length=$length.',
        );
      }
    } finally {
      calloc.free(oldProtect);
    }
  }

  @override
  void free(NativeMemoryBlock block) {
    final result = _virtualFree(block.pointer.cast(), 0, _memRelease);
    if (result == 0) {
      throw StateError('VirtualFree failed.');
    }
  }

  // Ported from Provision compat/windows.d protectionToWindows. Windows
  // has no write-without-read protection, so a writable page always
  // maps to a *_READWRITE constant.
  static int _protection({
    required bool readable,
    required bool writable,
    required bool executable,
  }) => switch ((executable, writable, readable)) {
    (true, true, _) => _pageExecuteReadwrite,
    (true, false, true) => _pageExecuteRead,
    (true, false, false) => _pageExecute,
    (false, true, _) => _pageReadwrite,
    (false, false, true) => _pageReadonly,
    (false, false, false) => _pageNoaccess,
  };
}
