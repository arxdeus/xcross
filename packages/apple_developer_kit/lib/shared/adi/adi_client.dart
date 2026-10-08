// Ported from Provision's lib/provision/adi.d — `class ADI`'s public
// methods, and the `ADIError` enum / `toString(ADIError)` message table /
// `ADIException` (https://github.com/Dadoum/Provision, LGPLv2 — see
// LICENSE/NOTICE.md). Native buffer lifetime here is copy-then-dispose
// instead of upstream's RAII structs; see NOTICE.md.

import 'dart:typed_data';

import 'package:apple_developer_kit/src/shared/adi/adi_client.dart';
import 'package:meta/meta.dart';

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
