// @Native bindings to the sysv_abi_bridge code asset built by
// hook/build.dart. On Windows x64 these rearrange SysV <-> MS ABI; on
// other hosts the C side is an identity stub (host ABI is already SysV).

import 'dart:ffi';

/// Wraps an MS-ABI function so Android/SysV callers can invoke it.
@Native<Pointer<Void> Function(Pointer<Void>, Int32)>(isLeaf: true)
external Pointer<Void> provision_sysv_wrap_export(
  Pointer<Void> msAbiFn,
  int argc,
);

/// Wraps a SysV function so Dart/MS-ABI callers can invoke it.
@Native<Pointer<Void> Function(Pointer<Void>, Int32)>(isLeaf: true)
external Pointer<Void> provision_sysv_wrap_import(
  Pointer<Void> sysvFn,
  int argc,
);

/// Publishes [msAbiFn] into an ELF GOT as a SysV-callable address.
Pointer<Void> sysvExport(Pointer<Void> msAbiFn, int argc) {
  final wrapped = provision_sysv_wrap_export(msAbiFn, argc);
  if (wrapped == nullptr) {
    throw StateError('provision_sysv_wrap_export failed for argc=$argc');
  }
  return wrapped;
}

/// Makes a SysV ADI symbol callable from Dart via [asFunction].
Pointer<NativeFunction<T>> sysvImport<T extends Function>(
  Pointer<NativeFunction<T>> sysvFn,
  int argc,
) {
  final wrapped = provision_sysv_wrap_import(sysvFn.cast(), argc);
  if (wrapped == nullptr) {
    throw StateError('provision_sysv_wrap_import failed for argc=$argc');
  }
  return wrapped.cast();
}
