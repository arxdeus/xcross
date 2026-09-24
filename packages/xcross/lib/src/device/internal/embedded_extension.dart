import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// An app extension already embedded in a built `.app`, as seen at
/// sign-and-install time.
///
/// The build-time [IosAppExtension] describes a *target*; this describes the
/// `PlugIns/<Name>.appex` that came out of it, after its identifier has been
/// qualified for the signing team.
@immutable
final class EmbeddedExtension {
  const EmbeddedExtension({
    required this.bundleId,
    required this.appGroups,
    this.path,
  });

  /// The `.appex` directory, when known.
  final String? path;

  /// The extension's (already qualified) `CFBundleIdentifier`.
  final String bundleId;

  /// App Groups this extension needs to share a container with its host.
  final List<String> appGroups;
}

/// Reads entitlement facts back off a built `.appex`.
abstract final class AppExtensionEntitlements {
  /// `com.apple.security.application-groups` declared by the `.appex` at
  /// [appexPath].
  ///
  /// The build writes the groups into the extension's `Info.plist` under
  /// [appGroupsInfoKey] precisely so this stage can recover them without
  /// re-reading the Xcode project, which may not even be present when a
  /// prebuilt `.app` is signed.
  static List<String> appGroupsOf(String appexPath) {
    final plist = File(p.join(appexPath, 'Info.plist'));
    if (!plist.existsSync()) return const [];

    final array = RegExp(
      '<key>\\s*$appGroupsInfoKey\\s*</key>\\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist.readAsStringSync());
    if (array == null) return const [];

    return [
      for (final match in RegExp(
        '<string>([^<]*)</string>',
      ).allMatches(array.group(1)!))
        if (_usable(match.group(1))) match.group(1)!.trim(),
    ];
  }

  static bool _usable(String? group) {
    final value = group?.trim();
    return value != null && value.isNotEmpty && !value.contains(r'$');
  }

  /// Private `Info.plist` key the extension build uses to record the App
  /// Groups from the target's entitlements file.
  static const appGroupsInfoKey = 'XCrossAppGroups';
}
