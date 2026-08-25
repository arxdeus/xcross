import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';

/// Whether any package in the resolved package graph has a build hook.
bool hasNativeAssetsBuildHooks(String projectRoot) {
  final packageConfig = File(
    p.join(projectRoot, '.dart_tool', 'package_config.json'),
  );
  if (!packageConfig.existsSync()) return false;

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

  final configUri = packageConfig.uri;
  for (final package in json['packages']! as List<Object?>) {
    if (package is! Map<String, Object?> || package['rootUri'] is! String) {
      continue;
    }
    try {
      final root = configUri.resolve(package['rootUri']! as String);
      if (!root.isScheme('file')) continue;
      final rootDirectory = Uri.directory(root.toFilePath());
      if (File.fromUri(rootDirectory.resolve('hook/build.dart')).existsSync()) {
        return true;
      }
    } on FormatException {
      // A malformed package entry cannot contain a discoverable local hook.
      continue;
    }
  }
  return false;
}
