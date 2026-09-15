import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';

/// The entitlements a Compose build recorded in the app's `Info.plist`.
///
/// A provisioning profile grants some keys generically - `associated-domains` as
/// `*`, for instance - so signing with the profile's dictionary alone leaves the
/// app declaring Apple's wildcard instead of the domains it actually needs, and
/// an `ASWebAuthenticationSession` callback for one of those domains is refused.
/// The assembler writes the app target's own entitlements here so the signer can
/// prefer them, without needing the Xcode project at signing time.
abstract final class AppEntitlements {
  /// Private `Info.plist` key the Compose assembler writes the declared
  /// entitlements to. Not an iOS key; it exists only between assembly and
  /// signing.
  static const infoPlistKey = 'XCrossEntitlements';

  /// The declared entitlements recorded for the `.app` at [appPath].
  static Map<String, Object?> of(String appPath) {
    final plist = File(p.join(appPath, 'Info.plist'));
    if (!plist.existsSync()) return const {};
    final object = PropertyListSerialization.propertyListWithString(
      plist.readAsStringSync(),
    );
    if (object is! Map) return const {};
    final declared = object[infoPlistKey];
    if (declared is! Map) return const {};
    return declared.cast<String, Object?>();
  }
}
