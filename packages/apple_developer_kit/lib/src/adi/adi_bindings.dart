// Ported from Provision's lib/provision/adi.d
// (https://github.com/Dadoum/Provision, LGPLv2 — see LICENSE/NOTICE.md).
//
// The `extern(C) function` aliases declared at the top of adi.d, and the
// obfuscated symbol strings passed to AndroidLibrary.load() in ADI's
// constructor, are ported here verbatim. Do not change argument order,
// types, or symbol names without re-checking upstream: the native library
// exports these functions under obfuscated (but stable) names rather than
// the documented `ADI*` names used for the Dart field names below.
//
// On Windows, looked-up symbols are SysV and must be wrapped with
// sysvImport before Dart's MS-ABI asFunction can call them (mirrors
// Provision's androidInvoke / @sysv). On Linux the wrap is skipped
// entirely — the host ABI is already SysV.

import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/src/adi/loader/internal/sysv_abi_bridge.dart';
import 'package:apple_developer_kit/src/adi/loader/loader.dart';
import 'package:ffi/ffi.dart';

// Native (C) and Dart call signatures, paired per ADI function. The
// native side is ported verbatim from adi.d's `extern(C)` aliases.

typedef ADILoadLibraryWithPathNative = Int32 Function(Pointer<Utf8> path);
typedef ADILoadLibraryWithPathDart = int Function(Pointer<Utf8> path);

typedef ADISetAndroidIDNative =
    Int32 Function(Pointer<Uint8> identifier, Uint32 length);
typedef ADISetAndroidIDDart =
    int Function(Pointer<Uint8> identifier, int length);

typedef ADISetProvisioningPathNative = Int32 Function(Pointer<Utf8> path);
typedef ADISetProvisioningPathDart = int Function(Pointer<Utf8> path);

typedef ADIProvisioningEraseNative = Int32 Function(Uint64 dsId);
typedef ADIProvisioningEraseDart = int Function(int dsId);

typedef ADISynchronizeNative =
    Int32 Function(
      Uint64 dsId,
      Pointer<Uint8> serverIntermediateMetadata,
      Uint32 serverIntermediateMetadataLength,
      Pointer<Pointer<Uint8>> outMachineIdentifier,
      Pointer<Uint32> outMachineIdentifierLength,
      Pointer<Pointer<Uint8>> outSynchronizationResumeMetadata,
      Pointer<Uint32> outSynchronizationResumeMetadataLength,
    );
typedef ADISynchronizeDart =
    int Function(
      int dsId,
      Pointer<Uint8> serverIntermediateMetadata,
      int serverIntermediateMetadataLength,
      Pointer<Pointer<Uint8>> outMachineIdentifier,
      Pointer<Uint32> outMachineIdentifierLength,
      Pointer<Pointer<Uint8>> outSynchronizationResumeMetadata,
      Pointer<Uint32> outSynchronizationResumeMetadataLength,
    );

typedef ADIProvisioningDestroyNative = Int32 Function(Uint32 session);
typedef ADIProvisioningDestroyDart = int Function(int session);

typedef ADIProvisioningEndNative =
    Int32 Function(
      Uint32 session,
      Pointer<Uint8> persistentTokenMetadata,
      Uint32 persistentTokenMetadataLength,
      Pointer<Uint8> trustKey,
      Uint32 trustKeyLength,
    );
typedef ADIProvisioningEndDart =
    int Function(
      int session,
      Pointer<Uint8> persistentTokenMetadata,
      int persistentTokenMetadataLength,
      Pointer<Uint8> trustKey,
      int trustKeyLength,
    );

typedef ADIProvisioningStartNative =
    Int32 Function(
      Uint64 dsId,
      Pointer<Uint8> serverProvisioningIntermediateMetadata,
      Uint32 serverProvisioningIntermediateMetadataLength,
      Pointer<Pointer<Uint8>> outClientProvisioningIntermediateMetadata,
      Pointer<Uint32> outClientProvisioningIntermediateMetadataLength,
      Pointer<Uint32> outSession,
    );
typedef ADIProvisioningStartDart =
    int Function(
      int dsId,
      Pointer<Uint8> serverProvisioningIntermediateMetadata,
      int serverProvisioningIntermediateMetadataLength,
      Pointer<Pointer<Uint8>> outClientProvisioningIntermediateMetadata,
      Pointer<Uint32> outClientProvisioningIntermediateMetadataLength,
      Pointer<Uint32> outSession,
    );

typedef ADIGetLoginCodeNative = Int32 Function(Uint64 dsId);
typedef ADIGetLoginCodeDart = int Function(int dsId);

typedef ADIDisposeNative = Int32 Function(Pointer<Void> ptr);
typedef ADIDisposeDart = int Function(Pointer<Void> ptr);

typedef ADIOTPRequestNative =
    Int32 Function(
      Uint64 dsId,
      Pointer<Pointer<Uint8>> outMachineIdentifier,
      Pointer<Uint32> outMachineIdentifierLength,
      Pointer<Pointer<Uint8>> outOneTimePassword,
      Pointer<Uint32> outOneTimePasswordLength,
    );
typedef ADIOTPRequestDart =
    int Function(
      int dsId,
      Pointer<Pointer<Uint8>> outMachineIdentifier,
      Pointer<Uint32> outMachineIdentifierLength,
      Pointer<Pointer<Uint8>> outOneTimePassword,
      Pointer<Uint32> outOneTimePasswordLength,
    );

/// Raw FFI bindings to the ADI (Apple Device Identity) native functions
/// exported by `libstoreservicescore.so`, resolved by their obfuscated
/// (but stable) symbol names.
///
/// The `argc` passed alongside each symbol is the SysV thunk arity used
/// by the Windows ABI bridge; it must match the native signature above
/// it.
class AdiNativeBindings {
  AdiNativeBindings(LoadedNativeLibrary lib)
    : adiLoadLibraryWithPath = _lookup<ADILoadLibraryWithPathNative>(
        lib,
        'kq56gsgHG6',
        1,
      ).asFunction(),
      adiSetAndroidId = _lookup<ADISetAndroidIDNative>(
        lib,
        'Sph98paBcz',
        2,
      ).asFunction(),
      adiSetProvisioningPath = _lookup<ADISetProvisioningPathNative>(
        lib,
        'nf92ngaK92',
        1,
      ).asFunction(),
      adiProvisioningErase = _lookup<ADIProvisioningEraseNative>(
        lib,
        'p435tmhbla',
        1,
      ).asFunction(),
      adiSynchronize = _lookup<ADISynchronizeNative>(
        lib,
        'tn46gtiuhw',
        7,
      ).asFunction(),
      adiProvisioningDestroy = _lookup<ADIProvisioningDestroyNative>(
        lib,
        'fy34trz2st',
        1,
      ).asFunction(),
      adiProvisioningEnd = _lookup<ADIProvisioningEndNative>(
        lib,
        'uv5t6nhkui',
        5,
      ).asFunction(),
      adiProvisioningStart = _lookup<ADIProvisioningStartNative>(
        lib,
        'rsegvyrt87',
        6,
      ).asFunction(),
      adiGetLoginCode = _lookup<ADIGetLoginCodeNative>(
        lib,
        'aslgmuibau',
        1,
      ).asFunction(),
      adiDispose = _lookup<ADIDisposeNative>(lib, 'jk24uiwqrg', 1).asFunction(),
      adiOtpRequest = _lookup<ADIOTPRequestNative>(
        lib,
        'qi864985u0',
        5,
      ).asFunction();

  final ADILoadLibraryWithPathDart adiLoadLibraryWithPath;
  final ADISetAndroidIDDart adiSetAndroidId;
  final ADISetProvisioningPathDart adiSetProvisioningPath;
  final ADIProvisioningEraseDart adiProvisioningErase;
  final ADISynchronizeDart adiSynchronize;
  final ADIProvisioningDestroyDart adiProvisioningDestroy;
  final ADIProvisioningEndDart adiProvisioningEnd;
  final ADIProvisioningStartDart adiProvisioningStart;
  final ADIGetLoginCodeDart adiGetLoginCode;
  final ADIDisposeDart adiDispose;
  final ADIOTPRequestDart adiOtpRequest;

  static Pointer<NativeFunction<T>> _lookup<T extends Function>(
    LoadedNativeLibrary lib,
    String symbol,
    int argc,
  ) {
    final raw = lib.lookup<T>(symbol);
    if (!Platform.isWindows) return raw;
    return SysvAbiBridge.sysvImport(raw, argc);
  }
}
