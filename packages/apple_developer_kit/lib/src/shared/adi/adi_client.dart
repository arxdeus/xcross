// Ported from Provision's lib/provision/adi.d — `class ADI`'s public
// methods, and the `ADIError` enum / `toString(ADIError)` message table /
// `ADIException` (https://github.com/Dadoum/Provision, LGPLv2 — see
// LICENSE/NOTICE.md). Native buffer lifetime here is copy-then-dispose
// instead of upstream's RAII structs; see NOTICE.md.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/shared/adi/adi_client.dart';
import 'package:apple_developer_kit/src/shared/adi/adi_bindings.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Result of [AdiClient.synchronize].
///
/// Ported from `ADI.SynchronizationResumeMetadata` in adi.d.
@internal
@immutable
class AdiSynchronizationResult {
  const AdiSynchronizationResult({
    required this.synchronizationResumeMetadata,
    required this.machineIdentifier,
  });

  final Uint8List synchronizationResumeMetadata;
  final Uint8List machineIdentifier;
}

/// Idiomatic Dart wrapper around the native ADI (Apple Device Identity)
/// library, mirroring the public surface of upstream Provision's `ADI` D
/// class (`lib/provision/adi.d`).
///
/// This wraps [AdiNativeBindings]: it takes care of native buffer
/// lifetime (copying `out` buffers into Dart-owned [Uint8List]s and
/// disposing the native allocation immediately) and translates non-zero
/// ADI return codes into [AdiException].
///
/// Every scratch buffer is arena-allocated through [malloc] explicitly:
/// the arena's own default is `calloc`, and zero-filling buffers the
/// native side is expected to fill would be a behaviour change.
@internal
class AdiClient {
  AdiClient._(this._bindings);

  /// Loads `libstoreservicescore.so` from [nativeLibraryDir] and
  /// constructs an [AdiClient] bound to it.
  ///
  /// `libCoreADI.so` (expected alongside it in [nativeLibraryDir]) is
  /// NOT preloaded here: per upstream adi.d, the D caller never loads it
  /// directly either — it's pulled in lazily by `libstoreservicescore.so`
  /// itself via an internal `dlopen()` call, which our custom loader
  /// intercepts and emulates (see `native_symbol_stubs.dart`). See
  /// NOTICE.md for the load-order caveat.
  ///
  /// Mirrors `ADI.this(string libraryPath)` in adi.d.
  factory AdiClient.fromDirectory(
    String nativeLibraryDir, {
    required NativeLibraryLoader loader,
  }) {
    final libraryDir = nativeLibraryDir;
    final storeServicesPath = p.join(libraryDir, 'libstoreservicescore.so');
    final storeServicesCore = loader.load(storeServicesPath);

    final client = AdiClient._(AdiNativeBindings(storeServicesCore));
    client._loadLibrary(libraryDir);
    return client;
  }

  final AdiNativeBindings _bindings;

  String? _provisioningPath;
  String? _identifier;

  /// Directory ADI persists its provisioning state to. Ported from
  /// `ADI.provisioningPath` in adi.d.
  String? get provisioningPath => _provisioningPath;

  set provisioningPath(String? path) {
    if (path == null) return;
    using((arena) {
      _check(
        _bindings.adiSetProvisioningPath(path.toNativeUtf8(allocator: arena)),
      );
      _provisioningPath = path;
    }, malloc);
  }

  /// The Android ID (device identifier) ADI derives its identity from.
  /// Ported from `ADI.identifier` in adi.d.
  String? get identifier => _identifier;

  set identifier(String? identifier) {
    if (identifier == null) return;
    final bytes = Uint8List.fromList(utf8.encode(identifier));
    using((arena) {
      _check(_bindings.adiSetAndroidId(_copy(bytes, arena), bytes.length));
      _identifier = identifier;
    }, malloc);
  }

  /// Erases all provisioning state for [dsId]. Ported from
  /// `ADI.eraseProvisioning` in adi.d.
  Future<void> eraseProvisioning(int dsId) async {
    _check(_bindings.adiProvisioningErase(dsId));
  }

  /// Re-synchronizes an already-provisioned device against
  /// [serverIntermediateMetadata]. Ported from `ADI.synchronize` in adi.d.
  Future<AdiSynchronizationResult> synchronize(
    int dsId,
    Uint8List serverIntermediateMetadata,
  ) async {
    return using((arena) {
      final outMid = arena<Pointer<Uint8>>();
      final outMidLength = arena<Uint32>();
      final outSrm = arena<Pointer<Uint8>>();
      final outSrmLength = arena<Uint32>();

      _check(
        _bindings.adiSynchronize(
          dsId,
          _copy(serverIntermediateMetadata, arena),
          serverIntermediateMetadata.length,
          outMid,
          outMidLength,
          outSrm,
          outSrmLength,
        ),
      );

      return AdiSynchronizationResult(
        machineIdentifier: _takeBytes(outMid.value, outMidLength.value),
        synchronizationResumeMetadata: _takeBytes(
          outSrm.value,
          outSrmLength.value,
        ),
      );
    }, malloc);
  }

  /// Destroys an in-progress provisioning [session]. Ported from
  /// `ADI.destroyProvisioning` in adi.d.
  Future<void> destroyProvisioning(int session) async {
    _check(_bindings.adiProvisioningDestroy(session));
  }

  /// Completes provisioning [session] with the server's `ptm`/`tk`
  /// response. Ported from `ADI.endProvisioning` in adi.d.
  Future<void> endProvisioning(
    int session,
    Uint8List persistentTokenMetadata,
    Uint8List trustKey,
  ) async {
    using((arena) {
      _check(
        _bindings.adiProvisioningEnd(
          session,
          _copy(persistentTokenMetadata, arena),
          persistentTokenMetadata.length,
          _copy(trustKey, arena),
          trustKey.length,
        ),
      );
    }, malloc);
  }

  /// Starts a new provisioning session against server-provided
  /// intermediate metadata (`spim`, from Apple's `midStartProvisioning`
  /// endpoint). Ported from `ADI.startProvisioning` in adi.d.
  Future<AdiClientProvisioningIntermediateMetadata> startProvisioning(
    int dsId,
    Uint8List serverProvisioningIntermediateMetadata,
  ) async {
    return using((arena) {
      final outCpim = arena<Pointer<Uint8>>();
      final outCpimLength = arena<Uint32>();
      final outSession = arena<Uint32>();

      _check(
        _bindings.adiProvisioningStart(
          dsId,
          _copy(serverProvisioningIntermediateMetadata, arena),
          serverProvisioningIntermediateMetadata.length,
          outCpim,
          outCpimLength,
          outSession,
        ),
      );

      return AdiClientProvisioningIntermediateMetadata(
        clientProvisioningIntermediateMetadata: _takeBytes(
          outCpim.value,
          outCpimLength.value,
        ),
        session: outSession.value,
      );
    }, malloc);
  }

  /// Whether the device identified by [dsId] is already provisioned with
  /// Apple. Ported from `ADI.isMachineProvisioned` in adi.d.
  Future<bool> isMachineProvisioned(int dsId) async {
    final errorCode = _bindings.adiGetLoginCode(dsId);
    if (errorCode == 0) return true;
    if (errorCode == AdiErrorCode.notProvisioned.code) return false;
    throw AdiException(errorCode);
  }

  /// Requests a one-time password (OTP) for [dsId], used as part of
  /// Apple's GrandSlam login flow. Ported from `ADI.requestOTP` in adi.d.
  Future<AdiOneTimePassword> requestOTP(int dsId) async {
    return using((arena) {
      final outMid = arena<Pointer<Uint8>>();
      final outMidLength = arena<Uint32>();
      final outOtp = arena<Pointer<Uint8>>();
      final outOtpLength = arena<Uint32>();

      _check(
        _bindings.adiOtpRequest(
          dsId,
          outMid,
          outMidLength,
          outOtp,
          outOtpLength,
        ),
      );

      return AdiOneTimePassword(
        machineIdentifier: _takeBytes(outMid.value, outMidLength.value),
        oneTimePassword: _takeBytes(outOtp.value, outOtpLength.value),
      );
    }, malloc);
  }

  void _loadLibrary(String nativeLibraryDir) {
    using((arena) {
      _check(
        _bindings.adiLoadLibraryWithPath(
          nativeLibraryDir.toNativeUtf8(allocator: arena),
        ),
      );
    }, malloc);
  }

  Pointer<Uint8> _copy(Uint8List data, Allocator allocator) {
    final ptr = allocator<Uint8>(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    return ptr;
  }

  /// Copies an ADI-owned `out` buffer into Dart memory and hands the
  /// native allocation straight back to ADI.
  Uint8List _takeBytes(Pointer<Uint8> ptr, int length) {
    if (ptr == nullptr || length == 0) return Uint8List(0);
    final copy = Uint8List.fromList(ptr.asTypedList(length));
    _check(_bindings.adiDispose(ptr.cast<Void>()));
    return copy;
  }

  void _check(int errorCode) {
    if (errorCode != 0) {
      throw AdiException(errorCode);
    }
  }
}
