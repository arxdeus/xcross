/// SysV <-> MS ABI bridge wrappers around the @Native externals below.
library;

import 'dart:ffi';

import 'package:meta/meta.dart';

/// Wraps an MS-ABI function so Android/SysV callers can invoke it.
@internal
@Native<Pointer<Void> Function(Pointer<Void>, Int32)>(
  assetId:
      'package:apple_developer_kit/src/host/shared/adi/loader/internal/sysv_abi_bridge.dart',
  symbol: 'provision_sysv_wrap_export',
  isLeaf: true,
)
external Pointer<Void> provisionSysvWrapExport(Pointer<Void> msAbiFn, int argc);

/// Wraps a SysV function so Dart/MS-ABI callers can invoke it.
@internal
@Native<Pointer<Void> Function(Pointer<Void>, Int32)>(
  assetId:
      'package:apple_developer_kit/src/host/shared/adi/loader/internal/sysv_abi_bridge.dart',
  symbol: 'provision_sysv_wrap_import',
  isLeaf: true,
)
external Pointer<Void> provisionSysvWrapImport(Pointer<Void> sysvFn, int argc);

@internal
@Native<Int32 Function(Pointer<Void>, Size)>(
  assetId:
      'package:apple_developer_kit/src/host/shared/adi/loader/internal/sysv_abi_bridge.dart',
  symbol: 'provision_windows_arm64_prepare_code',
)
external int provisionWindowsArm64PrepareCode(
  Pointer<Void> code,
  int byteLength,
);

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
