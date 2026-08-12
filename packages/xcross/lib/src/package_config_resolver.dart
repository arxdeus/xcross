import 'dart:io';

import 'package:package_config/package_config.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Discovers the Dart package configuration used by a Flutter project.
abstract final class PackageConfigResolver {
  /// Finds the nearest package configuration at [projectRoot] or an ancestor.
  static Future<String?> find(String projectRoot) async {
    final result = await findPackageConfigAndFile(
      Directory(projectRoot),
      // ignore: avoid_redundant_argument_values
      minVersion: 2, // Explicitly exclude legacy `.packages` resolution.
    );
    return result?.file.path;
  }

  /// Finds the package configuration or reports how to create it.
  static Future<String> require(String projectRoot) async {
    final packageConfig = await find(projectRoot);
    if (packageConfig != null) return packageConfig;
    throw FlutterBuildError(
      'package_config.json not found from $projectRoot; '
      'run `flutter pub get` or `dart pub get` first.',
    );
  }
}
