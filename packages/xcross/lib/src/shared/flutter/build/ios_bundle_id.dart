import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/project/pbx_project_reader.dart';

/// Resolves the iOS product bundle identifier the way Flutter tooling does on
/// non-macOS hosts (no `xcodebuild -showBuildSettings`).
///
/// Order:
///   1. Literal `CFBundleIdentifier` from `ios/Runner/Info.plist` (no `$`).
///   2. `PRODUCT_BUNDLE_IDENTIFIER` of the *application* target in
///      `ios/*.xcodeproj/project.pbxproj` (never an app extension target).
///   3. First `PRODUCT_BUNDLE_IDENTIFIER` in the pbxproj (legacy fallback).
@internal
final class IosBundleId {
  IosBundleId(this.fileSystem, this.paths, this.projects);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final PbxProjectReader projects;

  /// Flutter's `_productBundleIdPattern` from `xcode_project.dart`.
  static final _productBundleIdPattern = RegExp(
    r'''^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(["']?)(.*?)\1;\s*$''',
    multiLine: true,
  );

  static final _cfBundleIdentifierPattern = RegExp(
    r'<key>CFBundleIdentifier</key>\s*<string>([^<]*)</string>',
  );

  static const _applicationProductType = 'com.apple.product-type.application';

  /// Resolve the bundle id for the Flutter project at [projectRoot].
  ///
  /// Throws [FlutterBuildError] when neither a literal plist value nor a
  /// pbxproj `PRODUCT_BUNDLE_IDENTIFIER` can be found.
  String resolve(String projectRoot) {
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

  String? _cfBundleIdentifierFromPlist(String projectRoot) {
    final file = fileSystem.file(
      paths.join(projectRoot, 'ios', 'Runner', 'Info.plist'),
    );
    if (!file.existsSync()) return null;
    final match = _cfBundleIdentifierPattern.firstMatch(
      file.readAsStringSync(),
    );
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  String? _productBundleIdFromPbxproj(String projectRoot) {
    final pbxproj = _findPbxproj(projectRoot);
    if (pbxproj == null) return null;

    // Projects with app extensions (share extensions, widgets, ...) declare
    // several PRODUCT_BUNDLE_IDENTIFIERs, and the extension's often comes
    // first in the file. Resolve through the application target when the
    // project graph parses, and only then fall back to a first-match scan.
    final fromAppTarget = _appTargetBundleId(pbxproj.path);
    if (fromAppTarget != null) return fromAppTarget;

    final match = _productBundleIdPattern.firstMatch(
      pbxproj.readAsStringSync(),
    );
    return _clean(match?.group(2));
  }

  /// Bundle id of the `com.apple.product-type.application` target, preferring
  /// a target literally named `Runner`.
  String? _appTargetBundleId(String pbxprojPath) {
    final project = projects.parseFile(pbxprojPath);
    if (project == null) return null;

    String? fallback;
    for (final target in project.nativeTargets) {
      if (target.string('productType') != _applicationProductType) continue;
      final bundleId = _clean(
        project.buildSetting(target, 'PRODUCT_BUNDLE_IDENTIFIER'),
      );
      if (bundleId == null) continue;
      if (target.string('name') == 'Runner') return bundleId;
      fallback ??= bundleId;
    }
    return fallback;
  }

  static String? _clean(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty || value.contains(r'$')) return null;
    return value;
  }

  /// Prefer `Runner.xcodeproj`, otherwise the first `*.xcodeproj` under `ios/`.
  File? _findPbxproj(String projectRoot) {
    final iosDir = fileSystem.directory(paths.join(projectRoot, 'ios'));
    if (!iosDir.existsSync()) return null;

    final runner = fileSystem.file(
      paths.join(iosDir.path, 'Runner.xcodeproj', 'project.pbxproj'),
    );
    if (runner.existsSync()) return runner;

    for (final entity in iosDir.listSync()) {
      if (entity is! Directory) continue;
      if (!entity.path.endsWith('.xcodeproj')) continue;
      final candidate = fileSystem.file(
        paths.join(entity.path, 'project.pbxproj'),
      );
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }
}
