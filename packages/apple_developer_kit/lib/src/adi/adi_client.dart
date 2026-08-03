// Ported from Provision's lib/provision/adi.d — `class ADI`'s public
// methods, and the `ADIError` enum / `toString(ADIError)` message table /
// `ADIException` (https://github.com/Dadoum/Provision, LGPLv2 — see
// LICENSE/NOTICE.md). Native buffer lifetime here is copy-then-dispose
// instead of upstream's RAII structs; see NOTICE.md.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'package:apple_developer_kit/src/adi/adi_bindings.dart';
import 'package:apple_developer_kit/src/adi/loader/loader.dart';
import 'package:apple_developer_kit/src/adi/loader/loader_posix.dart';
import 'package:apple_developer_kit/src/adi/loader/loader_windows.dart';

/// Default loader for the current host: Windows ELF+SysV bridge, or Linux
/// POSIX mmap loader. See NOTICE.md for why plain dlopen/LoadLibrary is
/// unsafe for these Android libraries.
NativeLibraryLoader defaultNativeLibraryLoader() {
  if (Platform.isWindows) return WindowsNativeLibraryLoader();
  if (Platform.isLinux) return PosixNativeLibraryLoader();
  throw UnsupportedError(
    'provision_dart ADI loader supports Linux and Windows only '
    '(got ${Platform.operatingSystem}).',
  );
}

/// Known ADI native error codes, ported verbatim from the `ADIError` enum
/// in adi.d.
enum AdiErrorCode {
  invalidParams(-45001),
  invalidParams2(-45002),
  invalidTrustKey(-45003),
  ptmTkNotMatchingState(-45006),
  invalidInputDataParamHeader(-45018),
  unknownAdiFunction(-45019),
  invalidInputDataParamBody(-45020),
  unknownSession(-45025),
  emptySession(-45026),
  invalidDataHeader(-45031),
  dataTooShort(-45032),
  invalidDataBody(-45033),
  unknownAdiCallFlags(-45034),
  timeError(-45036),
  emptyHardwareIds(-45046),
  filesystemError(-45054),
  notProvisioned(-45061),
  noProvisioningToErase(-45062),
  pendingSession(-45063),
  sessionAlreadyDone(-45066),
  libraryLoadingFailed(-45075);

  const AdiErrorCode(this.code);

  final int code;

  static AdiErrorCode? fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

/// Thrown when a native ADI call returns a non-zero error code.
///
/// Ported from `ADIException`/`ADIError`/`toString(ADIError)` in adi.d;
/// the error code -> message mapping is copied verbatim from upstream.
class AdiException implements Exception {
  AdiException(this.errorCode);

  final int errorCode;

  /// The known [AdiErrorCode] for [errorCode], or `null` if it isn't one
  /// of the codes upstream documents.
  AdiErrorCode? get error => AdiErrorCode.fromCode(errorCode);

  /// Human-readable description, ported verbatim from adi.d's
  /// `toString(ADIError)`.
  String get message {
    switch (errorCode) {
      case -45001:
        return 'invalid parameters ($errorCode), or missing initialization '
            'bits, you need to set an identifier and a valid provisioning '
            'path first!';
      case -45002:
        return 'invalid parameters (for decipher) ($errorCode)';
      case -45003:
        return 'invalid Trust Key ($errorCode)';
      case -45006:
        return 'ptm and tk are not matching the transmitted cpim ($errorCode)';
      case -45018:
        return 'invalid input data header (first uint) (pointer is correct '
            'tho) ($errorCode)';
      case -45019:
        return "vdfut768ig doesn't know the asked function ($errorCode)";
      case -45020:
        return 'invalid input data (not the first uint) ($errorCode)';
      case -45025:
        return 'unknown session ($errorCode)';
      case -45026:
        return 'empty session ($errorCode)';
      case -45031:
        return 'invalid data (header) ($errorCode)';
      case -45032:
        return 'data too short ($errorCode)';
      case -45033:
        return 'invalid data (body) ($errorCode)';
      case -45034:
        return 'unknown ADI call flags ($errorCode)';
      case -45036:
        return 'time error ($errorCode)';
      case -45046:
        return 'identifier generation failure: empty hardware ids ($errorCode)';
      case -45054:
        return 'generic libc/file manipulation error ($errorCode)';
      case -45061:
        return 'not provisioned ($errorCode)';
      case -45062:
        return 'cannot erase provisioning: not provisioned ($errorCode)';
      case -45063:
        return 'provisioning first step is already pending ($errorCode)';
      case -45066:
        return '2nd step fail: session already consumed ($errorCode)';
      case -45075:
        return 'library loading error ($errorCode)';
      default:
        return 'unknown ADI error ($errorCode)';
    }
  }

  @override
  String toString() => 'AdiException: $message';
}

/// Result of [AdiClient.synchronize].
///
/// Ported from `ADI.SynchronizationResumeMetadata` in adi.d.
class AdiSynchronizationResult {
  const AdiSynchronizationResult({
    required this.synchronizationResumeMetadata,
    required this.machineIdentifier,
  });

  final Uint8List synchronizationResumeMetadata;
  final Uint8List machineIdentifier;
}

/// Result of [AdiClient.startProvisioning].
///
/// Ported from `ADI.ClientProvisioningIntermediateMetadata` in adi.d.
class AdiClientProvisioningIntermediateMetadata {
  const AdiClientProvisioningIntermediateMetadata({
    required this.clientProvisioningIntermediateMetadata,
    required this.session,
  });

  final Uint8List clientProvisioningIntermediateMetadata;
  final int session;
}

/// Result of [AdiClient.requestOTP].
///
/// Ported from `ADI.OneTimePassword` in adi.d.
class AdiOneTimePassword {
  const AdiOneTimePassword({
    required this.oneTimePassword,
    required this.machineIdentifier,
  });

  final Uint8List oneTimePassword;
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
class AdiClient {
  AdiClient._(this._bindings);

  final AdiNativeBindings _bindings;

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
    NativeLibraryLoader? loader,
  }) {
    final resolvedLoader = loader ?? defaultNativeLibraryLoader();
    final storeServicesPath = p.join(nativeLibraryDir, 'libstoreservicescore.so');
    final storeServicesCore = resolvedLoader.load(storeServicesPath);

    final client = AdiClient._(AdiNativeBindings(storeServicesCore));
    client._loadLibrary(nativeLibraryDir);
    return client;
  }

  void _loadLibrary(String nativeLibraryDir) {
    final pathPtr = nativeLibraryDir.toNativeUtf8();
    try {
      _unwrap(_bindings.adiLoadLibraryWithPath(pathPtr));
    } finally {
      malloc.free(pathPtr);
    }
  }

  String? _provisioningPath;

  /// Directory ADI persists its provisioning state to. Ported from
  /// `ADI.provisioningPath` in adi.d.
  String? get provisioningPath => _provisioningPath;

  set provisioningPath(String? path) {
    if (path == null) return;
    final pathPtr = path.toNativeUtf8();
    try {
      _unwrap(_bindings.adiSetProvisioningPath(pathPtr));
      _provisioningPath = path;
    } finally {
      malloc.free(pathPtr);
    }
  }

  String? _identifier;

  /// The Android ID (device identifier) ADI derives its identity from.
  /// Ported from `ADI.identifier` in adi.d.
  String? get identifier => _identifier;

  set identifier(String? identifier) {
    if (identifier == null) return;
    final bytes = Uint8List.fromList(utf8.encode(identifier));
    final ptr = malloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      _unwrap(_bindings.adiSetAndroidId(ptr, bytes.length));
      _identifier = identifier;
    } finally {
      malloc.free(ptr);
    }
  }

  /// Erases all provisioning state for [dsId]. Ported from
  /// `ADI.eraseProvisioning` in adi.d.
  Future<void> eraseProvisioning(int dsId) async {
    _unwrap(_bindings.adiProvisioningErase(dsId));
  }

  /// Re-synchronizes an already-provisioned device against
  /// [serverIntermediateMetadata]. Ported from `ADI.synchronize` in adi.d.
  Future<AdiSynchronizationResult> synchronize(
    int dsId,
    Uint8List serverIntermediateMetadata,
  ) async {
    final inputPtr = _copyToNative(serverIntermediateMetadata);
    final outMid = malloc<Pointer<Uint8>>();
    final outMidLength = malloc<Uint32>();
    final outSrm = malloc<Pointer<Uint8>>();
    final outSrmLength = malloc<Uint32>();
    try {
      _unwrap(_bindings.adiSynchronize(
        dsId,
        inputPtr,
        serverIntermediateMetadata.length,
        outMid,
        outMidLength,
        outSrm,
        outSrmLength,
      ));

      return AdiSynchronizationResult(
        machineIdentifier: _copyAndDispose(outMid.value, outMidLength.value),
        synchronizationResumeMetadata: _copyAndDispose(outSrm.value, outSrmLength.value),
      );
    } finally {
      malloc.free(inputPtr);
      malloc.free(outMid);
      malloc.free(outMidLength);
      malloc.free(outSrm);
      malloc.free(outSrmLength);
    }
  }

  /// Destroys an in-progress provisioning [session]. Ported from
  /// `ADI.destroyProvisioning` in adi.d.
  Future<void> destroyProvisioning(int session) async {
    _unwrap(_bindings.adiProvisioningDestroy(session));
  }

  /// Completes provisioning [session] with the server's `ptm`/`tk`
  /// response. Ported from `ADI.endProvisioning` in adi.d.
  Future<void> endProvisioning(
    int session,
    Uint8List persistentTokenMetadata,
    Uint8List trustKey,
  ) async {
    final ptmPtr = _copyToNative(persistentTokenMetadata);
    final tkPtr = _copyToNative(trustKey);
    try {
      _unwrap(_bindings.adiProvisioningEnd(
        session,
        ptmPtr,
        persistentTokenMetadata.length,
        tkPtr,
        trustKey.length,
      ));
    } finally {
      malloc.free(ptmPtr);
      malloc.free(tkPtr);
    }
  }

  /// Starts a new provisioning session against server-provided
  /// intermediate metadata (`spim`, from Apple's `midStartProvisioning`
  /// endpoint). Ported from `ADI.startProvisioning` in adi.d.
  Future<AdiClientProvisioningIntermediateMetadata> startProvisioning(
    int dsId,
    Uint8List serverProvisioningIntermediateMetadata,
  ) async {
    final inputPtr = _copyToNative(serverProvisioningIntermediateMetadata);
    final outCpim = malloc<Pointer<Uint8>>();
    final outCpimLength = malloc<Uint32>();
    final outSession = malloc<Uint32>();
    try {
      _unwrap(_bindings.adiProvisioningStart(
        dsId,
        inputPtr,
        serverProvisioningIntermediateMetadata.length,
        outCpim,
        outCpimLength,
        outSession,
      ));

      return AdiClientProvisioningIntermediateMetadata(
        clientProvisioningIntermediateMetadata: _copyAndDispose(outCpim.value, outCpimLength.value),
        session: outSession.value,
      );
    } finally {
      malloc.free(inputPtr);
      malloc.free(outCpim);
      malloc.free(outCpimLength);
      malloc.free(outSession);
    }
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
    final outMid = malloc<Pointer<Uint8>>();
    final outMidLength = malloc<Uint32>();
    final outOtp = malloc<Pointer<Uint8>>();
    final outOtpLength = malloc<Uint32>();
    try {
      _unwrap(_bindings.adiOtpRequest(
        dsId,
        outMid,
        outMidLength,
        outOtp,
        outOtpLength,
      ));

      return AdiOneTimePassword(
        machineIdentifier: _copyAndDispose(outMid.value, outMidLength.value),
        oneTimePassword: _copyAndDispose(outOtp.value, outOtpLength.value),
      );
    } finally {
      malloc.free(outMid);
      malloc.free(outMidLength);
      malloc.free(outOtp);
      malloc.free(outOtpLength);
    }
  }

  Pointer<Uint8> _copyToNative(Uint8List data) {
    final ptr = malloc<Uint8>(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    return ptr;
  }

  Uint8List _copyAndDispose(Pointer<Uint8> ptr, int length) {
    if (ptr == nullptr || length == 0) return Uint8List(0);
    final copy = Uint8List.fromList(ptr.asTypedList(length));
    _unwrap(_bindings.adiDispose(ptr.cast<Void>()));
    return copy;
  }

  void _unwrap(int errorCode) {
    if (errorCode != 0) {
      throw AdiException(errorCode);
    }
  }
}
