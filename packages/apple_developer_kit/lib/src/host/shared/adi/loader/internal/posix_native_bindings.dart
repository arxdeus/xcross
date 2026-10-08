import 'dart:ffi';

import 'package:meta/meta.dart';

@internal
@Native<Void Function(Pointer<Void>, IntPtr)>(
  assetId:
      'package:apple_developer_kit/src/host/shared/adi/loader/internal/sysv_abi_bridge.dart',
  symbol: 'provision_clear_cache',
  isLeaf: true,
)
external void provisionClearCache(Pointer<Void> address, int size);

@internal
@Native<Pointer<Void> Function(Pointer<Char>)>(
  assetId:
      'package:apple_developer_kit/src/host/shared/adi/loader/internal/sysv_abi_bridge.dart',
  symbol: 'provision_posix_symbol',
  isLeaf: true,
)
external Pointer<Void> provisionPosixSymbol(Pointer<Char> name);
