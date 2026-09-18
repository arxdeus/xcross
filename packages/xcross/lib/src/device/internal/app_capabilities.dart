import 'dart:io';

import 'package:path/path.dart' as p;

/// Capability types a Compose build recorded in the app's `Info.plist`.
///
/// The assembler writes the App Store Connect capabilities the project's
/// entitlements need under [infoPlistKey], mirroring how the Flutter packer
/// records App Groups. The signing stage then recovers them without re-reading
/// the Xcode project, which may not even be present when a prebuilt `.app` is
/// signed.
///
/// A profile only grants what the App ID has switched on, so these have to be
/// enabled before it is issued: an entitlement that no profile backs is inert,
/// and the ceremony that needs it fails at runtime with nothing in the build log
/// to explain it.
abstract final class AppCapabilities {
  /// Private `Info.plist` key the Compose assembler writes the capability types
  /// to. Not a real iOS key; it exists only between assembly and signing.
  static const infoPlistKey = 'XCrossCapabilities';

  /// The capability types recorded for the `.app` at [appPath].
  static List<String> of(String appPath) {
    final plist = File(p.join(appPath, 'Info.plist'));
    if (!plist.existsSync()) return const [];

    final array = RegExp(
      '<key>\\s*$infoPlistKey\\s*</key>\\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist.readAsStringSync());
    if (array == null) return const [];

    return [
      for (final match in RegExp(
        '<string>([^<]*)</string>',
      ).allMatches(array.group(1)!))
        if (match.group(1)!.trim() case final String type when type.isNotEmpty)
          type,
    ];
  }
}
