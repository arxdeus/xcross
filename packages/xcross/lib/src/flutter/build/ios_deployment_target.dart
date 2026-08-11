import 'dart:io';

import 'package:path/path.dart' as p;

final class IosDeploymentTarget {
  const IosDeploymentTarget(this.version);

  static const fallback = IosDeploymentTarget('13.0');

  static final _deploymentTargetPattern = RegExp(
    r'''^\s*IPHONEOS_DEPLOYMENT_TARGET\s*=\s*(["']?)(.*?)\1;\s*$''',
    multiLine: true,
  );

  static final _minimumOsPattern = RegExp(
    r'<key>MinimumOSVersion</key>\s*<string>([^<]*)</string>',
  );

  static final _versionPattern = RegExp(r'^\d+(?:\.\d+)*$');

  final String version;

  String get buildTriple => 'arm64-apple-ios$version';

  static IosDeploymentTarget resolve(String projectRoot) {
    final fromPbxproj = _deploymentTargetFromPbxproj(projectRoot);
    if (fromPbxproj != null) return IosDeploymentTarget(fromPbxproj);

    final fromPlist = _minimumOsVersionFromPlist(projectRoot);
    if (fromPlist != null) return IosDeploymentTarget(fromPlist);

    return fallback;
  }

  static String? _deploymentTargetFromPbxproj(String projectRoot) {
    final pbxproj = _findPbxproj(projectRoot);
    if (pbxproj == null) return null;

    String? highest;
    for (final match in _deploymentTargetPattern.allMatches(
      pbxproj.readAsStringSync(),
    )) {
      final candidate = _normalize(match.group(2));
      if (candidate == null) continue;
      if (highest == null || _compareVersions(candidate, highest) > 0) {
        highest = candidate;
      }
    }
    return highest;
  }

  static String? _minimumOsVersionFromPlist(String projectRoot) {
    final file = File(p.join(projectRoot, 'ios', 'Runner', 'Info.plist'));
    if (!file.existsSync()) return null;
    final match = _minimumOsPattern.firstMatch(file.readAsStringSync());
    return _normalize(match?.group(1));
  }

  static String? _normalize(String? value) {
    final candidate = value?.trim();
    if (candidate == null || !_versionPattern.hasMatch(candidate)) return null;
    return candidate;
  }

  static int _compareVersions(String left, String right) {
    final leftParts = left.split('.').map(int.parse).toList();
    final rightParts = right.split('.').map(int.parse).toList();
    final length = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;

    for (var index = 0; index < length; index += 1) {
      final leftPart = index < leftParts.length ? leftParts[index] : 0;
      final rightPart = index < rightParts.length ? rightParts[index] : 0;
      if (leftPart != rightPart) return leftPart.compareTo(rightPart);
    }
    return 0;
  }

  /// Prefer `Runner.xcodeproj`, otherwise the first `*.xcodeproj` under `ios/`.
  static File? _findPbxproj(String projectRoot) {
    final iosDir = Directory(p.join(projectRoot, 'ios'));
    if (!iosDir.existsSync()) return null;

    final runner = File(
      p.join(iosDir.path, 'Runner.xcodeproj', 'project.pbxproj'),
    );
    if (runner.existsSync()) return runner;

    for (final entity in iosDir.listSync()) {
      if (entity is! Directory) continue;
      if (!entity.path.endsWith('.xcodeproj')) continue;
      final candidate = File(p.join(entity.path, 'project.pbxproj'));
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }
}
