import 'dart:io';

import 'package:meta/meta.dart';
import 'package:xcross/src/flutter/build/pbxproj.dart';

/// The version pair every bundle in an app must agree on.
///
/// iOS requires an embedded app extension's `CFBundleShortVersionString` and
/// `CFBundleVersion` to match its host app's; installd rejects a mismatched
/// pair, and a stale extension version silently breaks upgrades.
@immutable
final class IosBundleVersions {
  const IosBundleVersions({
    required this.shortVersion,
    required this.bundleVersion,
  });

  /// Fallbacks matching Flutter's own defaults.
  static const fallback = IosBundleVersions(
    shortVersion: '1.0.0',
    bundleVersion: '1',
  );

  /// `CFBundleShortVersionString`, from `MARKETING_VERSION`.
  final String shortVersion;

  /// `CFBundleVersion`, from `CURRENT_PROJECT_VERSION`.
  final String bundleVersion;

  /// Resolve the application target's versions from `project.pbxproj`.
  ///
  /// Xcode expands `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` from
  /// the *application* target's build settings, so those are read here rather
  /// than taking whichever value appears first in the file (which, in a
  /// project with extensions, is usually an extension's).
  // ignore: prefer_constructors_over_static_methods
  static IosBundleVersions resolve(
    String projectRoot, {
    String? buildName,
    String? buildNumber,
  }) {
    final settings = _applicationBuildSettings(projectRoot);
    return IosBundleVersions(
      shortVersion:
          buildName ??
          _setting(settings, 'MARKETING_VERSION') ??
          fallback.shortVersion,
      bundleVersion:
          buildNumber ??
          _setting(settings, 'CURRENT_PROJECT_VERSION') ??
          fallback.bundleVersion,
    );
  }

  static Map<String, Object?> _applicationBuildSettings(String projectRoot) {
    final pbxprojPath = PbxProject.findPbxproj(projectRoot);
    if (pbxprojPath == null) return const {};
    final project = PbxProject.parseFile(pbxprojPath);
    if (project == null) return const {};

    Map<String, Object?>? fallbackSettings;
    for (final target in project.nativeTargets) {
      if (target.string('productType') !=
          'com.apple.product-type.application') {
        continue;
      }
      final settings = project.buildSettings(target);
      if (target.string('name') == 'Runner') return settings;
      fallbackSettings ??= settings;
    }
    return fallbackSettings ?? const {};
  }

  static String? _setting(Map<String, Object?> settings, String key) {
    final value = settings[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    // An unresolved $(VAR) is worse than the documented default.
    if (trimmed.isEmpty || trimmed.contains(r'$')) return null;
    return trimmed;
  }

  /// Read `CFBundleShortVersionString`/`CFBundleVersion` straight out of a
  /// built `Info.plist`, used to make an extension match its host exactly.
  static IosBundleVersions? fromBuiltPlist(String plistPath) {
    final file = File(plistPath);
    if (!file.existsSync()) return null;
    final xml = file.readAsStringSync();

    final short = _plistString(xml, 'CFBundleShortVersionString');
    final bundle = _plistString(xml, 'CFBundleVersion');
    if (short == null || bundle == null) return null;
    return IosBundleVersions(shortVersion: short, bundleVersion: bundle);
  }

  static String? _plistString(String xml, String key) {
    final match = RegExp(
      '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(xml);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty || value.contains(r'$')) return null;
    return value;
  }

  @override
  String toString() => '$shortVersion ($bundleVersion)';
}
