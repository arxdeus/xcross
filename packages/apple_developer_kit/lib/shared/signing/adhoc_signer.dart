import 'dart:typed_data';

import 'package:apple_developer_kit/src/shared/signing/macho_signer.dart';

/// Writes ad-hoc code signatures (`codesign -s -`) that carry entitlements.
///
/// Needs no certificate or profile, so it runs at build time on Linux and
/// Windows. The result is what an unsigned `.ipa` should contain: external
/// re-signers (Sideloadly, AltStore, zsign, `fastlane resign`) take the
/// entitlements they apply from the binary's existing signature.
abstract final class AdHocSigner {
  /// Returns [bytes], a thin arm64 Mach-O, with its signature replaced.
  ///
  /// [entitlements] are embedded only for an `MH_EXECUTE`; a library gets an
  /// empty entitlement blob. [infoPlist] is hashed into special slot -1.
  /// Throws `AppleError` for a Mach-O the signer cannot lay out.
  static Uint8List sign(
    Uint8List bytes, {
    required String path,
    required String identifier,
    required Map<String, Object?> entitlements,
    Uint8List? infoPlist,
  }) => MachOSigner.adHoc().signBytes(
    path: path,
    bytes: bytes,
    identifier: identifier,
    teamIdentifier: null,
    entitlements: entitlements,
    infoPlistBytes: infoPlist,
  );
}
