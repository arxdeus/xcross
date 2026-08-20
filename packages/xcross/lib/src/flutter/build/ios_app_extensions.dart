import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/pbxproj.dart';

/// Product types xcross knows how to build as embedded app extensions.
///
/// `app-extension` covers share/action/notification extensions, the ones that
/// live in `<App>.app/PlugIns/<Name>.appex`. Watch apps, XPC services and
/// other nested-code kinds are deliberately excluded.
const _extensionProductTypes = {'com.apple.product-type.app-extension'};

const _applicationProductType = 'com.apple.product-type.application';

/// Extensions of files that belong in a target's compile-sources phase.
const _sourceExtensions = {'.swift', '.m', '.mm', '.c', '.cpp'};

/// Extensions that are never a compiled source nor a copyable resource:
/// build inputs Xcode consumes itself.
const _nonResourceExtensions = {
  '.h',
  '.hpp',
  '.plist',
  '.entitlements',
  '.modulemap',
  '.xcconfig',
  '.md',
  '.swiftinterface',
};

/// One iOS app-extension target discovered in `project.pbxproj`.
@immutable
final class IosAppExtension {
  const IosAppExtension({
    required this.name,
    required this.bundleId,
    required this.infoPlistPath,
    required this.sources,
    required this.resources,
    required this.entitlementsPath,
    required this.swiftVersion,
    required this.deploymentTarget,
    required this.appGroups,
  });

  /// Target name, e.g. `Share Extension`. Also the `.appex` bundle name.
  final String name;

  /// `PRODUCT_BUNDLE_IDENTIFIER` of the extension target. Must be prefixed by
  /// the host app's bundle id for iOS to load it.
  final String bundleId;

  /// Absolute path to the target's `INFOPLIST_FILE`, or null when unset.
  final String? infoPlistPath;

  /// Absolute paths of the target's compile sources (`.swift`, `.m`).
  final List<String> sources;

  /// Absolute paths of the target's resource files (storyboards, assets).
  final List<String> resources;

  /// Absolute path to the target's `CODE_SIGN_ENTITLEMENTS`, or null.
  final String? entitlementsPath;

  /// `SWIFT_VERSION`, defaulting to `5.0`.
  final String swiftVersion;

  /// `IPHONEOS_DEPLOYMENT_TARGET` of this target, or null to inherit the app's.
  final String? deploymentTarget;

  /// `com.apple.security.application-groups` values read from the target's
  /// entitlements file. These must be provisioned on the App ID for the
  /// extension and the host app to share a container.
  final List<String> appGroups;

  /// Bundle directory name inside `PlugIns/`.
  String get bundleName => '$name.appex';

  /// Swift module name for this target: the target name with everything that
  /// is not identifier-safe replaced by `_`, which is what Xcode does
  /// (`Share Extension` → `Share_Extension`).
  String get moduleName {
    final sanitized = name.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
    return RegExp('^[0-9]').hasMatch(sanitized) ? '_$sanitized' : sanitized;
  }

  /// The executable name inside the `.appex`. Xcode uses the target name,
  /// which may contain spaces; iOS accepts that.
  String get executableName => name;

  /// The [bundleId] suffix beyond [hostBundleId], e.g. `.Share-Extension`.
  /// Returns null when this extension is not nested under the host app id,
  /// which iOS rejects at install time.
  String? suffixUnder(String hostBundleId) {
    if (!bundleId.startsWith('$hostBundleId.')) return null;
    return bundleId.substring(hostBundleId.length);
  }
}

/// Discovers app-extension targets in a Flutter project's Xcode project.
abstract final class IosAppExtensions {
  /// All app-extension targets declared in `<projectRoot>/ios/*.xcodeproj`.
  ///
  /// Returns an empty list when the project has no extensions, no pbxproj, or
  /// the pbxproj cannot be parsed: extensions are an optional feature and a
  /// parse failure must never break an otherwise fine app build.
  static List<IosAppExtension> discover(String projectRoot) {
    final pbxprojPath = findPbxproj(projectRoot);
    if (pbxprojPath == null) return const [];
    final project = PbxProject.parseFile(pbxprojPath);
    if (project == null) return const [];

    final extensions = <IosAppExtension>[];
    for (final target in project.nativeTargets) {
      final productType = target.string('productType');
      if (!_extensionProductTypes.contains(productType)) continue;

      final name = target.string('name') ?? target.string('productName');
      final bundleId = project.buildSetting(
        target,
        'PRODUCT_BUNDLE_IDENTIFIER',
      );
      // A target whose id is still an unresolved $(VAR) can't be provisioned.
      if (name == null || bundleId == null || bundleId.contains(r'$')) continue;

      final entitlements = _resolveProjectPath(
        project,
        project.buildSetting(target, 'CODE_SIGN_ENTITLEMENTS'),
      );

      // Xcode 16 targets may list files explicitly, via a synchronized folder
      // group, or both; merging the two keeps either project style building.
      final synchronized = project.synchronizedFiles(target);
      final sources = <String>{
        ...project.buildPhaseFiles(target, 'PBXSourcesBuildPhase'),
        ...synchronized.where(
          (file) => _sourceExtensions.contains(p.extension(file)),
        ),
      }.toList();
      final resources = <String>{
        ...project.buildPhaseFiles(target, 'PBXResourcesBuildPhase'),
        ...synchronized.where((file) {
          final extension = p.extension(file);
          return !_sourceExtensions.contains(extension) &&
              !_nonResourceExtensions.contains(extension);
        }),
      }.toList();

      extensions.add(
        IosAppExtension(
          name: name,
          bundleId: bundleId,
          infoPlistPath: _resolveProjectPath(
            project,
            project.buildSetting(target, 'INFOPLIST_FILE'),
          ),
          sources: sources,
          resources: resources,
          entitlementsPath: entitlements,
          swiftVersion: project.buildSetting(target, 'SWIFT_VERSION') ?? '5.0',
          deploymentTarget: project.buildSetting(
            target,
            'IPHONEOS_DEPLOYMENT_TARGET',
          ),
          appGroups: readAppGroups(entitlements),
        ),
      );
    }

    // Stable order so builds and signing are reproducible.
    extensions.sort((a, b) => a.name.compareTo(b.name));
    return extensions;
  }

  /// The application target's name, used to tell the host app apart from its
  /// extensions. Returns null when no application target is present.
  static String? applicationTargetName(String projectRoot) {
    final pbxprojPath = findPbxproj(projectRoot);
    if (pbxprojPath == null) return null;
    final project = PbxProject.parseFile(pbxprojPath);
    if (project == null) return null;
    for (final target in project.nativeTargets) {
      if (target.string('productType') == _applicationProductType) {
        return target.string('name');
      }
    }
    return null;
  }

  /// Absolute path to the application target's `CODE_SIGN_ENTITLEMENTS`, or
  /// null when the project declares none.
  static String? applicationEntitlements(String projectRoot) {
    final pbxprojPath = findPbxproj(projectRoot);
    if (pbxprojPath == null) return null;
    final project = PbxProject.parseFile(pbxprojPath);
    if (project == null) return null;

    for (final target in project.nativeTargets) {
      if (target.string('productType') != _applicationProductType) continue;
      final entitlements = _resolveProjectPath(
        project,
        project.buildSetting(target, 'CODE_SIGN_ENTITLEMENTS'),
      );
      if (entitlements != null) return entitlements;
    }
    return null;
  }

  /// `com.apple.security.application-groups` entries in the entitlements
  /// plist at [path]. Empty when the file is missing or declares no groups.
  static List<String> readAppGroups(String? path) {
    if (path == null) return const [];
    final file = File(path);
    if (!file.existsSync()) return const [];

    final xml = file.readAsStringSync();
    final key = RegExp(
      r'<key>\s*com\.apple\.security\.application-groups\s*</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(xml);
    if (key == null) return const [];

    return RegExp('<string>([^<]*)</string>')
        .allMatches(key.group(1)!)
        .map((match) => match.group(1)!.trim())
        // `$(VAR)`-templated groups can't be provisioned as-is.
        .where((group) => group.isNotEmpty && !group.contains(r'$'))
        .toList();
  }

  /// Resolve a build-setting path (relative to `ios/`) to an absolute path.
  static String? _resolveProjectPath(PbxProject project, String? value) {
    if (value == null || value.isEmpty || value.contains(r'$')) return null;
    if (p.isAbsolute(value)) return value;
    return p.normalize(p.join(project.projectDirectory, value));
  }

  /// Path to the project's `project.pbxproj`, preferring `Runner.xcodeproj`.
  static String? findPbxproj(String projectRoot) {
    final iosDir = Directory(p.join(projectRoot, 'ios'));
    if (!iosDir.existsSync()) return null;

    final runner = File(
      p.join(iosDir.path, 'Runner.xcodeproj', 'project.pbxproj'),
    );
    if (runner.existsSync()) return runner.path;

    for (final entity in iosDir.listSync()) {
      if (entity is! Directory) continue;
      if (!entity.path.endsWith('.xcodeproj')) continue;
      final candidate = File(p.join(entity.path, 'project.pbxproj'));
      if (candidate.existsSync()) return candidate.path;
    }
    return null;
  }
}
