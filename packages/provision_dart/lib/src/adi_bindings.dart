// Ported from Provision's lib/provision/adi.d
// (https://github.com/Dadoum/Provision, LGPLv2 — see LICENSE/NOTICE.md).
//
// The `extern(C) function` aliases declared at the top of adi.d, and the
// obfuscated symbol strings passed to AndroidLibrary.load() in ADI's
// constructor, are ported here verbatim. Do not change argument order,
// types, or symbol names without re-checking upstream: the native library
// exports these functions under obfuscated (but stable) names rather than
// the documented `ADI*` names used for the Dart field names below.

import 'dart:ffi';

import 'package:ffi/ffi.dart' show Utf8;

import 'loader/loader.dart';

// --- Native (C) call signatures, ported from adi.d's `extern(C)` aliases ---

typedef ADILoadLibraryWithPathNative = Int32 Function(Pointer<Utf8> path);
typedef ADISetAndroidIDNative = Int32 Function(Pointer<Uint8> identifier, Uint32 length);
typedef ADISetProvisioningPathNative = Int32 Function(Pointer<Utf8> path);
typedef ADIProvisioningEraseNative = Int32 Function(Uint64 dsId);
typedef ADISynchronizeNative = Int32 Function(
  Uint64 dsId,
  Pointer<Uint8> serverIntermediateMetadata,
  Uint32 serverIntermediateMetadataLength,
  Pointer<Pointer<Uint8>> outMachineIdentifier,
  Pointer<Uint32> outMachineIdentifierLength,
  Pointer<Pointer<Uint8>> outSynchronizationResumeMetadata,
  Pointer<Uint32> outSynchronizationResumeMetadataLength,
);
typedef ADIProvisioningDestroyNative = Int32 Function(Uint32 session);
typedef ADIProvisioningEndNative = Int32 Function(
  Uint32 session,
  Pointer<Uint8> persistentTokenMetadata,
  Uint32 persistentTokenMetadataLength,
  Pointer<Uint8> trustKey,
  Uint32 trustKeyLength,
);
typedef ADIProvisioningStartNative = Int32 Function(
  Uint64 dsId,
  Pointer<Uint8> serverProvisioningIntermediateMetadata,
  Uint32 serverProvisioningIntermediateMetadataLength,
  Pointer<Pointer<Uint8>> outClientProvisioningIntermediateMetadata,
  Pointer<Uint32> outClientProvisioningIntermediateMetadataLength,
  Pointer<Uint32> outSession,
);
typedef ADIGetLoginCodeNative = Int32 Function(Uint64 dsId);
typedef ADIDisposeNative = Int32 Function(Pointer<Void> ptr);
typedef ADIOTPRequestNative = Int32 Function(
  Uint64 dsId,
  Pointer<Pointer<Uint8>> outMachineIdentifier,
  Pointer<Uint32> outMachineIdentifierLength,
  Pointer<Pointer<Uint8>> outOneTimePassword,
  Pointer<Uint32> outOneTimePasswordLength,
);

// --- Dart-side call signatures ---

typedef ADILoadLibraryWithPathDart = int Function(Pointer<Utf8> path);
typedef ADISetAndroidIDDart = int Function(Pointer<Uint8> identifier, int length);
typedef ADISetProvisioningPathDart = int Function(Pointer<Utf8> path);
typedef ADIProvisioningEraseDart = int Function(int dsId);
typedef ADISynchronizeDart = int Function(
  int dsId,
  Pointer<Uint8> serverIntermediateMetadata,
  int serverIntermediateMetadataLength,
  Pointer<Pointer<Uint8>> outMachineIdentifier,
  Pointer<Uint32> outMachineIdentifierLength,
  Pointer<Pointer<Uint8>> outSynchronizationResumeMetadata,
  Pointer<Uint32> outSynchronizationResumeMetadataLength,
);
typedef ADIProvisioningDestroyDart = int Function(int session);
typedef ADIProvisioningEndDart = int Function(
  int session,
  Pointer<Uint8> persistentTokenMetadata,
  int persistentTokenMetadataLength,
  Pointer<Uint8> trustKey,
  int trustKeyLength,
);
typedef ADIProvisioningStartDart = int Function(
  int dsId,
  Pointer<Uint8> serverProvisioningIntermediateMetadata,
  int serverProvisioningIntermediateMetadataLength,
  Pointer<Pointer<Uint8>> outClientProvisioningIntermediateMetadata,
  Pointer<Uint32> outClientProvisioningIntermediateMetadataLength,
  Pointer<Uint32> outSession,
);
typedef ADIGetLoginCodeDart = int Function(int dsId);
typedef ADIDisposeDart = int Function(Pointer<Void> ptr);
typedef ADIOTPRequestDart = int Function(
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
/// See `lib/src/adi_client.dart` for an idiomatic Dart wrapper around
/// these; use that instead of this class directly unless you specifically
/// need raw pointer access.
class AdiNativeBindings {
  AdiNativeBindings(LoadedNativeLibrary storeServicesCore)
      : adiLoadLibraryWithPath = storeServicesCore
            .lookup<ADILoadLibraryWithPathNative>('kq56gsgHG6')
            .asFunction<ADILoadLibraryWithPathDart>(),
        adiSetAndroidId = storeServicesCore
            .lookup<ADISetAndroidIDNative>('Sph98paBcz')
            .asFunction<ADISetAndroidIDDart>(),
        adiSetProvisioningPath = storeServicesCore
            .lookup<ADISetProvisioningPathNative>('nf92ngaK92')
            .asFunction<ADISetProvisioningPathDart>(),
        adiProvisioningErase = storeServicesCore
            .lookup<ADIProvisioningEraseNative>('p435tmhbla')
            .asFunction<ADIProvisioningEraseDart>(),
        adiSynchronize = storeServicesCore
            .lookup<ADISynchronizeNative>('tn46gtiuhw')
            .asFunction<ADISynchronizeDart>(),
        adiProvisioningDestroy = storeServicesCore
            .lookup<ADIProvisioningDestroyNative>('fy34trz2st')
            .asFunction<ADIProvisioningDestroyDart>(),
        adiProvisioningEnd = storeServicesCore
            .lookup<ADIProvisioningEndNative>('uv5t6nhkui')
            .asFunction<ADIProvisioningEndDart>(),
        adiProvisioningStart = storeServicesCore
            .lookup<ADIProvisioningStartNative>('rsegvyrt87')
            .asFunction<ADIProvisioningStartDart>(),
        adiGetLoginCode = storeServicesCore
            .lookup<ADIGetLoginCodeNative>('aslgmuibau')
            .asFunction<ADIGetLoginCodeDart>(),
        adiDispose = storeServicesCore
            .lookup<ADIDisposeNative>('jk24uiwqrg')
            .asFunction<ADIDisposeDart>(),
        adiOtpRequest = storeServicesCore
            .lookup<ADIOTPRequestNative>('qi864985u0')
            .asFunction<ADIOTPRequestDart>();

  /// Tells ADI where to find its native libraries (a directory path).
  /// Ported from `ADILoadLibraryWithPath` (obfuscated symbol `kq56gsgHG6`).
  final ADILoadLibraryWithPathDart adiLoadLibraryWithPath;

  /// Sets the Android ID (device identifier) bytes ADI uses to derive its
  /// per-device identity. Ported from `ADISetAndroidID` (`Sph98paBcz`).
  final ADISetAndroidIDDart adiSetAndroidId;

  /// Sets the directory ADI persists its provisioning state to (e.g. the
  /// on-disk `adi.pb`). Ported from `ADISetProvisioningPath` (`nf92ngaK92`).
  final ADISetProvisioningPathDart adiSetProvisioningPath;

  /// Erases all provisioning state for the given `dsId`. Ported from
  /// `ADIProvisioningErase` (`p435tmhbla`).
  final ADIProvisioningEraseDart adiProvisioningErase;

  /// Re-synchronizes an already-provisioned device against
  /// server-provided intermediate metadata. Ported from `ADISynchronize`
  /// (`tn46gtiuhw`).
  final ADISynchronizeDart adiSynchronize;

  /// Destroys an in-progress (started but not finished) provisioning
  /// session. Ported from `ADIProvisioningDestroy` (`fy34trz2st`).
  final ADIProvisioningDestroyDart adiProvisioningDestroy;

  /// Completes a provisioning session started with [adiProvisioningStart],
  /// given the server's `ptm`/`tk` response. Ported from
  /// `ADIProvisioningEnd` (`uv5t6nhkui`).
  final ADIProvisioningEndDart adiProvisioningEnd;

  /// Starts a new provisioning session against server-provided
  /// intermediate metadata (`spim`). Ported from `ADIProvisioningStart`
  /// (`rsegvyrt87`).
  final ADIProvisioningStartDart adiProvisioningStart;

  /// Returns `0` if the device (identified by `dsId`) is already
  /// provisioned, or `-45061` (not provisioned) otherwise. Ported from
  /// `ADIGetLoginCode` (`aslgmuibau`).
  final ADIGetLoginCodeDart adiGetLoginCode;

  /// Frees a buffer previously allocated by the native library and
  /// returned through an `out` parameter of another ADI call. Every
  /// buffer returned by [adiSynchronize], [adiProvisioningStart], or
  /// [adiOtpRequest] must be released with this. Ported from `ADIDispose`
  /// (`jk24uiwqrg`).
  final ADIDisposeDart adiDispose;

  /// Requests a one-time password (OTP) and machine identifier for the
  /// given `dsId`, used to authenticate with Apple's GrandSlam login
  /// service. Ported from `ADIOTPRequest` (`qi864985u0`).
  final ADIOTPRequestDart adiOtpRequest;
}
