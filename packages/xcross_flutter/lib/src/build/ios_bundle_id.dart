import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:xcross_flutter/src/errors.dart';

/// Resolves the iOS product bundle identifier the way Flutter tooling does on
/// non-macOS hosts (no `xcodebuild -showBuildSettings`).
///
/// Order:
///   1. Literal `CFBundleIdentifier` from `ios/Runner/Info.plist` (no `$`).
///   2. First `PRODUCT_BUNDLE_IDENTIFIER` in `ios/*.xcodeproj/project.pbxproj`.
abstract final class IosBundleId {
  /// Flutter's `_productBundleIdPattern` from `xcode_project.dart`.
  static final _productBundleIdPattern = RegExp(
    r'''^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(["']?)(.*?)\1;\s*$''',
    multiLine: true,
  );

  static final _cfBundleIdentifierPattern = RegExp(
    r'<key>CFBundleIdentifier</key>\s*<string>([^<]*)</string>',
  );

  /// Resolve the bundle id for the Flutter project at [projectRoot].
  ///
  /// Throws [FlutterBuildError] when neither a literal plist value nor a pbxproj
  /// `PRODUCT_BUNDLE_IDENTIFIER` can be found.
  static String resolve(String projectRoot) {
    final fromPlist = _cfBundleIdentifierFromPlist(projectRoot);
    if (fromPlist != null && !fromPlist.contains(r'$')) {
      return fromPlist;
    }

    final fromPbxproj = _productBundleIdFromPbxproj(projectRoot);
    if (fromPbxproj != null && fromPbxproj.isNotEmpty) {
      return fromPbxproj;
    }

    throw FlutterBuildError(
      'Could not resolve iOS bundle identifier. Set CFBundleIdentifier in '
      'ios/Runner/Info.plist, or PRODUCT_BUNDLE_IDENTIFIER in '
      'ios/*.xcodeproj/project.pbxproj.',
    );
  }

  static String? _cfBundleIdentifierFromPlist(String projectRoot) {
    final file = File(p.join(projectRoot, 'ios', 'Runner', 'Info.plist'));
    if (!file.existsSync()) return null;
    final match = _cfBundleIdentifierPattern.firstMatch(
      file.readAsStringSync(),
    );
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Prefer `Runner.xcodeproj`, otherwise the first `*.xcodeproj` under `ios/`.
  static String? _productBundleIdFromPbxproj(String projectRoot) {
    final iosDir = Directory(p.join(projectRoot, 'ios'));
    if (!iosDir.existsSync()) return null;

    File? pbxproj;
    final runner = File(
      p.join(iosDir.path, 'Runner.xcodeproj', 'project.pbxproj'),
    );
    if (runner.existsSync()) {
      pbxproj = runner;
    } else {
      for (final entity in iosDir.listSync()) {
        if (entity is! Directory) continue;
        if (!entity.path.endsWith('.xcodeproj')) continue;
        final candidate = File(p.join(entity.path, 'project.pbxproj'));
        if (candidate.existsSync()) {
          pbxproj = candidate;
          break;
        }
      }
    }
    if (pbxproj == null) return null;

    final match = _productBundleIdPattern.firstMatch(
      pbxproj.readAsStringSync(),
    );
    final value = match?.group(2)?.trim();
    if (value == null || value.isEmpty || value.contains(r'$')) return null;
    return value;
  }
}
