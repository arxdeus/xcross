/// SysV <-> MS ABI bridge wrappers around the @Native externals below.
library;

// @Native bindings to the sysv_abi_bridge code asset built by
// hook/build.dart. On Windows x64 these rearrange SysV <-> MS ABI; on
// other hosts the C side is an identity stub (host ABI is already SysV).

import 'dart:ffi';

import 'package:meta/meta.dart';

/// Wraps an MS-ABI function so Android/SysV callers can invoke it.
@Native<Pointer<Void> Function(Pointer<Void>, Int32)>(
  symbol: 'provision_sysv_wrap_export',
  isLeaf: true,
)
external Pointer<Void> provisionSysvWrapExport(Pointer<Void> msAbiFn, int argc);

/// Wraps a SysV function so Dart/MS-ABI callers can invoke it.
@Native<Pointer<Void> Function(Pointer<Void>, Int32)>(
  symbol: 'provision_sysv_wrap_import',
  isLeaf: true,
)
external Pointer<Void> provisionSysvWrapImport(Pointer<Void> sysvFn, int argc);

/// Dart wrappers around the @Native externals.
@internal
abstract final class SysvAbiBridge {
  /// Publishes [msAbiFn] into an ELF GOT as a SysV-callable address.
  @useResult
  static Pointer<Void> sysvExport(Pointer<Void> msAbiFn, int argc) {
    final wrapped = provisionSysvWrapExport(msAbiFn, argc);
    if (wrapped == nullptr) {
      throw StateError('provision_sysv_wrap_export failed for argc=$argc');
    }
    return wrapped;
  }

  /// Makes a SysV ADI symbol callable from Dart via [asFunction].
  @useResult
  static Pointer<NativeFunction<T>> sysvImport<T extends Function>(
    Pointer<NativeFunction<T>> sysvFn,
    int argc,
  ) {
    final wrapped = provisionSysvWrapImport(sysvFn.cast(), argc);
    if (wrapped == nullptr) {
      throw StateError('provision_sysv_wrap_import failed for argc=$argc');
    }
    return wrapped.cast();
  }
}

@Native<Void Function(Pointer<Void>, IntPtr)>(
  symbol: 'provision_clear_cache',
  isLeaf: true,
)
external void provisionClearCache(Pointer<Void> address, int size);

@Native<Pointer<Void> Function(Pointer<Char>)>(
  symbol: 'provision_posix_symbol',
  isLeaf: true,
)
external Pointer<Void> provisionPosixSymbol(Pointer<Char> name);
