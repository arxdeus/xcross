import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';

@internal
final class IosDeploymentTargetResolver {
  IosDeploymentTargetResolver(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  static final _deploymentTargetPattern = RegExp(
    r'''^\s*IPHONEOS_DEPLOYMENT_TARGET\s*=\s*(["']?)(.*?)\1;\s*$''',
    multiLine: true,
  );

  static final _minimumOsPattern = RegExp(
    r'<key>MinimumOSVersion</key>\s*<string>([^<]*)</string>',
  );

  static final _versionPattern = RegExp(r'^\d+(?:\.\d+)*$');

  IosDeploymentTarget resolve(
    String projectRoot, {
    required IosBuildPlatformInterface platform,
  }) {
    final fromPbxproj = _deploymentTargetFromPbxproj(projectRoot);
    if (fromPbxproj != null) {
      return IosDeploymentTarget(fromPbxproj, platform: platform);
    }

    final fromPlist = _minimumOsVersionFromPlist(projectRoot);
    if (fromPlist != null) {
      return IosDeploymentTarget(fromPlist, platform: platform);
    }

    return IosDeploymentTarget(
      IosDeploymentTarget.fallbackVersion,
      platform: platform,
    );
  }

  String? _deploymentTargetFromPbxproj(String projectRoot) {
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

  String? _minimumOsVersionFromPlist(String projectRoot) {
    final file = fileSystem.file(
      paths.join(projectRoot, 'ios', 'Flutter', 'AppFrameworkInfo.plist'),
    );
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
  File? _findPbxproj(String projectRoot) {
    final iosDir = fileSystem.directory(paths.join(projectRoot, 'ios'));
    if (!iosDir.existsSync()) return null;

    final runner = fileSystem.file(
      paths.join(iosDir.path, 'Runner.xcodeproj', 'project.pbxproj'),
    );
    if (runner.existsSync()) return runner;

    final alternates =
        iosDir
            .listSync()
            .whereType<Directory>()
            .where((entity) => entity.path.endsWith('.xcodeproj'))
            .toList()
          ..sort((left, right) => left.path.compareTo(right.path));

    for (final entity in alternates) {
      final candidate = fileSystem.file(
        paths.join(entity.path, 'project.pbxproj'),
      );
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }
}
