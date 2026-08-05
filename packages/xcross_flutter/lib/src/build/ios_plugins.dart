import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross_flutter/src/errors.dart';
import 'package:yaml/yaml.dart';

/// One Flutter plugin's iOS native-code location, as recorded in
/// `.flutter-plugins-dependencies`.
@immutable
class IosPlugin {
  const IosPlugin({required this.name, required this.packageRoot});

  /// Pub package name (also the Dart class prefix / SPM directory name).
  final String name;

  /// Absolute path to the plugin's pub package root (NOT the `ios/` subdir).
  final String packageRoot;

  /// `<packageRoot>/ios/<name>/Package.swift` — the SPM manifest, if this
  /// plugin ships one.
  String get swiftPackageManifest => p.join(swiftPackageDir, 'Package.swift');

  /// Directory containing [swiftPackageManifest] (the SPM package root).
  String get swiftPackageDir => p.join(packageRoot, 'ios', name);

  /// `<packageRoot>/ios/<name>.podspec` — the CocoaPods podspec, if any.
  String get podspecPath => p.join(packageRoot, 'ios', '$name.podspec');

  /// Whether this plugin ships a Swift Package Manager manifest.
  bool get usesSwiftPackageManager => File(swiftPackageManifest).existsSync();

  /// Whether this plugin ships a CocoaPods podspec (may be true alongside
  /// [usesSwiftPackageManager] for dual-published plugins).
  bool get usesCocoaPods => File(podspecPath).existsSync();

  /// `flutter.plugin.platforms.ios.pluginClass` read from this plugin's own
  /// `pubspec.yaml`, or null if absent — e.g. a pure-Dart/FFI-only plugin, or
  /// a federated facade package (`path_provider`) with no direct native
  /// implementation (those declare `default_package:` instead, which isn't
  /// resolved here; the implementation package, e.g.
  /// `path_provider_foundation`, is a separate entry with its own
  /// `pluginClass`).
  String? get pluginClassIos {
    final file = File(p.join(packageRoot, 'pubspec.yaml'));
    if (!file.existsSync()) return null;

    final Object? pubspec;
    try {
      pubspec = loadYaml(file.readAsStringSync());
    } on Object {
      return null;
    }

    if (pubspec case {
      'flutter': {
        'plugin': {
          'platforms': {'ios': {'pluginClass': final String pluginClass}},
        },
      },
    }) {
      return pluginClass;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is IosPlugin &&
      other.name == name &&
      other.packageRoot == packageRoot;

  @override
  int get hashCode => Object.hash(name, packageRoot);

  @override
  String toString() => 'IosPlugin(name: $name, packageRoot: $packageRoot)';
}

/// Discovers a Flutter project's iOS native plugin dependencies from
/// `.flutter-plugins-dependencies` (written by `flutter pub get`).
abstract final class PluginDiscovery {
  /// Every iOS plugin listed in `<projectRoot>/.flutter-plugins-dependencies`.
  ///
  /// Returns an empty list (never throws) if the file is missing or has no
  /// `plugins.ios` entries — absence of the file just means no plugins were
  /// ever resolved (e.g. `flutter pub get` not yet run), not a build error;
  /// callers decide whether that's fatal.
  ///
  /// Throws [FlutterBuildError] only if the file exists but holds bad JSON.
  static Future<List<IosPlugin>> discover(String projectRoot) async {
    final file = File(p.join(projectRoot, '.flutter-plugins-dependencies'));
    if (!file.existsSync()) return const [];

    final Object? manifest;
    try {
      manifest = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw FlutterBuildError('${file.path}: invalid JSON: $e');
    }

    if (manifest case {'plugins': {'ios': final List<Object?> entries}}) {
      return [
        for (final entry in entries)
          if (entry case {'name': final String name, 'path': final String path})
            IosPlugin(name: name, packageRoot: _resolve(path, projectRoot)),
      ];
    }
    return const [];
  }

  static String _resolve(String path, String projectRoot) =>
      p.isAbsolute(path) ? path : p.join(projectRoot, path);
}
