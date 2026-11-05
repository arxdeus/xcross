import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/shared/apple/mach_o_code_signature.dart';

/// The entitlements a Compose build recorded in the app's `Info.plist`.
///
/// A provisioning profile grants some keys generically - `associated-domains` as
/// `*`, for instance - so signing with the profile's dictionary alone leaves the
/// app declaring Apple's wildcard instead of the domains it actually needs, and
/// an `ASWebAuthenticationSession` callback for one of those domains is refused.
/// The assembler writes the app target's own entitlements here so the signer can
/// prefer them, without needing the Xcode project at signing time.
@internal
final class AppEntitlements {
  const AppEntitlements({required this.fileSystem, required this.paths});
  final HostFileSystemInterface fileSystem;
  final HostPathsInterface paths;

  /// Private `Info.plist` key the Compose assembler writes the declared
  /// entitlements to. Not an iOS key; it exists only between assembly and
  /// signing.
  static const infoPlistKey = 'XCrossEntitlements';

  /// The declared entitlements recorded for the `.app` at [appPath].
  ///
  /// Absence is the normal case: only a Compose build writes [infoPlistKey],
  /// while this runs on the shared install path that also signs Flutter and
  /// prebuilt apps. Those bundles are read but never parsed - the key is looked
  /// for as text first - and a plist that cannot be parsed yields "nothing
  /// declared" rather than failing the install. The XML parser throws on a
  /// binary plist and on one without an `<?xml?>` declaration, neither of which
  /// is xcross's business to reject here: signing works off the profile, and
  /// these values only ever refine it.
  ///
  /// Without the key, the entitlements embedded in the main executable's
  /// code signature are used: a Flutter build writes the project's
  /// `CODE_SIGN_ENTITLEMENTS` there (ad-hoc) so that external re-signers see
  /// them, and reading them back here means no private key has to ship in an
  /// unsigned `.ipa`.
  Map<String, Object?> of(String appPath) {
    final plist = fileSystem.file(paths.context.join(appPath, 'Info.plist'));
    if (!plist.existsSync()) return const {};
    final String xml;
    try {
      xml = plist.readAsStringSync();
    } on FileSystemException {
      return const {};
    }
    if (!xml.contains(infoPlistKey)) return _embedded(appPath, xml);
    final Object? object;
    try {
      object = PropertyListSerialization.propertyListWithString(xml);
    } on Object {
      return const {};
    }
    if (object is! Map) return const {};
    final declared = object[infoPlistKey];
    if (declared is! Map) return const {};
    return declared.cast<String, Object?>();
  }

  Map<String, Object?> _embedded(String appPath, String infoPlistXml) {
    final executable = RegExp(
      r'<key>\s*CFBundleExecutable\s*</key>\s*<string>([^<]+)</string>',
    ).firstMatch(infoPlistXml)?.group(1)?.trim();
    if (executable == null || executable.isEmpty) return const {};
    final file = fileSystem.file(paths.context.join(appPath, executable));
    final String? entitlements;
    try {
      if (!file.existsSync()) return const {};
      entitlements = MachOCodeSignature.embeddedEntitlementsXml(
        file.readAsBytesSync(),
      );
    } on FileSystemException {
      return const {};
    }
    if (entitlements == null) return const {};
    try {
      final object = PropertyListSerialization.propertyListWithString(
        entitlements,
      );
      return object is Map ? object.cast<String, Object?>() : const {};
    } on Object {
      return const {};
    }
  }
}
