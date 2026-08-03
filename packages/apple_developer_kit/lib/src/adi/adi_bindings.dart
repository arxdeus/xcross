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
// Provision's androidInvoke / @sysv). On Linux the wrap is an identity.

import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/src/adi/loader/loader.dart';
import 'package:apple_developer_kit/src/adi/loader/sysv_abi_bridge.dart';
import 'package:ffi/ffi.dart' show Utf8;

// --- Native (C) call signatures, ported from adi.d's `extern(C)` aliases ---

typedef ADILoadLibraryWithPathNative = Int32 Function(Pointer<Utf8> path);
typedef ADISetAndroidIDNative =
    Int32 Function(Pointer<Uint8> identifier, Uint32 length);
typedef ADISetProvisioningPathNative = Int32 Function(Pointer<Utf8> path);
typedef ADIProvisioningEraseNative = Int32 Function(Uint64 dsId);
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
typedef ADIProvisioningDestroyNative = Int32 Function(Uint32 session);
typedef ADIProvisioningEndNative =
    Int32 Function(
      Uint32 session,
      Pointer<Uint8> persistentTokenMetadata,
      Uint32 persistentTokenMetadataLength,
      Pointer<Uint8> trustKey,
      Uint32 trustKeyLength,
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
typedef ADIGetLoginCodeNative = Int32 Function(Uint64 dsId);
typedef ADIDisposeNative = Int32 Function(Pointer<Void> ptr);
typedef ADIOTPRequestNative =
    Int32 Function(
      Uint64 dsId,
      Pointer<Pointer<Uint8>> outMachineIdentifier,
      Pointer<Uint32> outMachineIdentifierLength,
      Pointer<Pointer<Uint8>> outOneTimePassword,
      Pointer<Uint32> outOneTimePasswordLength,
    );

// --- Dart-side call signatures ---

typedef ADILoadLibraryWithPathDart = int Function(Pointer<Utf8> path);
typedef ADISetAndroidIDDart =
    int Function(Pointer<Uint8> identifier, int length);
typedef ADISetProvisioningPathDart = int Function(Pointer<Utf8> path);
typedef ADIProvisioningEraseDart = int Function(int dsId);
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
typedef ADIProvisioningDestroyDart = int Function(int session);
typedef ADIProvisioningEndDart =
    int Function(
      int session,
      Pointer<Uint8> persistentTokenMetadata,
      int persistentTokenMetadataLength,
      Pointer<Uint8> trustKey,
      int trustKeyLength,
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
typedef ADIGetLoginCodeDart = int Function(int dsId);
typedef ADIDisposeDart = int Function(Pointer<Void> ptr);
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
class AdiNativeBindings {
  AdiNativeBindings(LoadedNativeLibrary storeServicesCore)
    : adiLoadLibraryWithPath = _lookup<ADILoadLibraryWithPathNative>(
        storeServicesCore,
        'kq56gsgHG6',
        1,
      ).asFunction<ADILoadLibraryWithPathDart>(),
      adiSetAndroidId = _lookup<ADISetAndroidIDNative>(
        storeServicesCore,
        'Sph98paBcz',
        2,
      ).asFunction<ADISetAndroidIDDart>(),
      adiSetProvisioningPath = _lookup<ADISetProvisioningPathNative>(
        storeServicesCore,
        'nf92ngaK92',
        1,
      ).asFunction<ADISetProvisioningPathDart>(),
      adiProvisioningErase = _lookup<ADIProvisioningEraseNative>(
        storeServicesCore,
        'p435tmhbla',
        1,
      ).asFunction<ADIProvisioningEraseDart>(),
      adiSynchronize = _lookup<ADISynchronizeNative>(
        storeServicesCore,
        'tn46gtiuhw',
        7,
      ).asFunction<ADISynchronizeDart>(),
      adiProvisioningDestroy = _lookup<ADIProvisioningDestroyNative>(
        storeServicesCore,
        'fy34trz2st',
        1,
      ).asFunction<ADIProvisioningDestroyDart>(),
      adiProvisioningEnd = _lookup<ADIProvisioningEndNative>(
        storeServicesCore,
        'uv5t6nhkui',
        5,
      ).asFunction<ADIProvisioningEndDart>(),
      adiProvisioningStart = _lookup<ADIProvisioningStartNative>(
        storeServicesCore,
        'rsegvyrt87',
        6,
      ).asFunction<ADIProvisioningStartDart>(),
      adiGetLoginCode = _lookup<ADIGetLoginCodeNative>(
        storeServicesCore,
        'aslgmuibau',
        1,
      ).asFunction<ADIGetLoginCodeDart>(),
      adiDispose = _lookup<ADIDisposeNative>(
        storeServicesCore,
        'jk24uiwqrg',
        1,
      ).asFunction<ADIDisposeDart>(),
      adiOtpRequest = _lookup<ADIOTPRequestNative>(
        storeServicesCore,
        'qi864985u0',
        5,
      ).asFunction<ADIOTPRequestDart>();

  static Pointer<NativeFunction<T>> _lookup<T extends Function>(
    LoadedNativeLibrary lib,
    String symbol,
    int argc,
  ) {
    final raw = lib.lookup<T>(symbol);
    if (!Platform.isWindows) return raw;
    return SysvAbiBridge.sysvImport(raw, argc);
  }

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
}
