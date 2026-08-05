// Ported from Provision's lib/provision/adi.d — `class ADI`'s public
// methods, and the `ADIError` enum / `toString(ADIError)` message table /
// `ADIException` (https://github.com/Dadoum/Provision, LGPLv2 — see
// LICENSE/NOTICE.md). Native buffer lifetime here is copy-then-dispose
// instead of upstream's RAII structs; see NOTICE.md.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/adi_bindings.dart';
import 'package:apple_developer_kit/src/adi/loader/loader.dart';
import 'package:apple_developer_kit/src/adi/loader/loader_posix.dart';
import 'package:apple_developer_kit/src/adi/loader/loader_windows.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

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

  static final Map<int, AdiErrorCode> _byCode = {
    for (final value in values) value.code: value,
  };

  static AdiErrorCode? fromCode(int code) => _byCode[code];
}

/// Thrown when a native ADI call returns a non-zero error code.
///
/// Ported from `ADIException`/`ADIError`/`toString(ADIError)` in adi.d;
/// the error code -> message mapping is copied verbatim from upstream.
@immutable
class AdiException implements Exception {
  const AdiException(this.errorCode);

  final int errorCode;

  /// The known [AdiErrorCode] for [errorCode], or `null` if it isn't one
  /// of the codes upstream documents.
  AdiErrorCode? get error => AdiErrorCode.fromCode(errorCode);

  /// Human-readable description, ported verbatim from adi.d's
  /// `toString(ADIError)`.
  String get message => switch (error) {
    AdiErrorCode.invalidParams =>
      'invalid parameters ($errorCode), or missing initialization '
          'bits, you need to set an identifier and a valid provisioning '
          'path first!',
    AdiErrorCode.invalidParams2 =>
      'invalid parameters (for decipher) ($errorCode)',
    AdiErrorCode.invalidTrustKey => 'invalid Trust Key ($errorCode)',
    AdiErrorCode.ptmTkNotMatchingState =>
      'ptm and tk are not matching the transmitted cpim ($errorCode)',
    AdiErrorCode.invalidInputDataParamHeader =>
      'invalid input data header (first uint) (pointer is correct '
          'tho) ($errorCode)',
    AdiErrorCode.unknownAdiFunction =>
      "vdfut768ig doesn't know the asked function ($errorCode)",
    AdiErrorCode.invalidInputDataParamBody =>
      'invalid input data (not the first uint) ($errorCode)',
    AdiErrorCode.unknownSession => 'unknown session ($errorCode)',
    AdiErrorCode.emptySession => 'empty session ($errorCode)',
    AdiErrorCode.invalidDataHeader => 'invalid data (header) ($errorCode)',
    AdiErrorCode.dataTooShort => 'data too short ($errorCode)',
    AdiErrorCode.invalidDataBody => 'invalid data (body) ($errorCode)',
    AdiErrorCode.unknownAdiCallFlags => 'unknown ADI call flags ($errorCode)',
    AdiErrorCode.timeError => 'time error ($errorCode)',
    AdiErrorCode.emptyHardwareIds =>
      'identifier generation failure: empty hardware ids ($errorCode)',
    AdiErrorCode.filesystemError =>
      'generic libc/file manipulation error ($errorCode)',
    AdiErrorCode.notProvisioned => 'not provisioned ($errorCode)',
    AdiErrorCode.noProvisioningToErase =>
      'cannot erase provisioning: not provisioned ($errorCode)',
    AdiErrorCode.pendingSession =>
      'provisioning first step is already pending ($errorCode)',
    AdiErrorCode.sessionAlreadyDone =>
      '2nd step fail: session already consumed ($errorCode)',
    AdiErrorCode.libraryLoadingFailed => 'library loading error ($errorCode)',
    null => 'unknown ADI error ($errorCode)',
  };

  @override
  String toString() => 'AdiException: $message';
}

/// Result of [AdiClient.synchronize].
///
/// Ported from `ADI.SynchronizationResumeMetadata` in adi.d.
@immutable
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
@immutable
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
@immutable
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
///
/// Every scratch buffer is arena-allocated through [malloc] explicitly:
/// the arena's own default is `calloc`, and zero-filling buffers the
/// native side is expected to fill would be a behaviour change.
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
    NativeLibraryLoader? loader,
  }) {
    final resolvedLoader = loader ?? AdiClient.defaultNativeLibraryLoader();
    final storeServicesPath = p.join(
      nativeLibraryDir,
      'libstoreservicescore.so',
    );
    final storeServicesCore = resolvedLoader.load(storeServicesPath);

    final client = AdiClient._(AdiNativeBindings(storeServicesCore));
    client._loadLibrary(nativeLibraryDir);
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

  /// Default loader for the current host: Windows ELF+SysV bridge, or Linux
  /// POSIX mmap loader. See NOTICE.md for why plain dlopen/LoadLibrary is
  /// unsafe for these Android libraries.
  @useResult
  static NativeLibraryLoader defaultNativeLibraryLoader() {
    if (Platform.isWindows) return WindowsNativeLibraryLoader();
    if (Platform.isLinux) return PosixNativeLibraryLoader();
    throw UnsupportedError(
      'provision_dart ADI loader supports Linux and Windows only '
      '(got ${Platform.operatingSystem}).',
    );
  }
}
