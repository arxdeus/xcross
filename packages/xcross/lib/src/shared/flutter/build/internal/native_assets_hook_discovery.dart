import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/packages/package_config_resolver.dart';

/// Whether any package in the resolved package graph has a build hook.
@internal
final class NativeAssetsHookDiscovery {
  const NativeAssetsHookDiscovery({
    required this.fileSystem,
    required this.paths,
    required this.packageConfigs,
  });
  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final PackageConfigResolver packageConfigs;
  Future<bool> hasBuildHooks(String projectRoot) async {
    final String configPath;
    try {
      configPath = await packageConfigs.require(projectRoot);
    } on FormatException catch (error) {
      throw FlutterBuildError(
        'Could not read package config from $projectRoot: malformed JSON '
        '($error). Run `flutter pub get` and retry.',
      );
    }
    final packageConfig = fileSystem.file(configPath);

    final Object? json;
    try {
      json = jsonDecode(packageConfig.readAsStringSync());
    } on FormatException catch (error) {
      throw FlutterBuildError(
        'Could not read ${packageConfig.path}: malformed JSON '
        '(${error.message}). Run `flutter pub get` and retry.',
      );
    } on FileSystemException catch (error) {
      throw FlutterBuildError(
        'Could not read ${packageConfig.path}: ${error.message}',
      );
    }

    if (json is! Map<String, Object?> || json['packages'] is! List<Object?>) {
      throw FlutterBuildError(
        'Could not read ${packageConfig.path}: expected a package_config with a '
        '`packages` list. Run `flutter pub get` and retry.',
      );
    }

    final configUri = paths.toUri(configPath);
    for (final package in json['packages']! as List<Object?>) {
      if (package is! Map<String, Object?> || package['rootUri'] is! String) {
        continue;
      }
      try {
        final root = configUri.resolve(package['rootUri']! as String);
        if (!root.isScheme('file')) continue;
        final rootDirectory = paths.fromUri(root);
        if (fileSystem
            .file(paths.join(rootDirectory, 'hook', 'build.dart'))
            .existsSync()) {
          return true;
        }
      } on FormatException {
        // A malformed package entry cannot contain a discoverable local hook.
        continue;
      }
    }
    return false;
  }
}
