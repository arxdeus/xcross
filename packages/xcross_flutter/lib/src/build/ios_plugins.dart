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

  /// Pub package name (also the plugin's Dart class prefix / SPM directory name).
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
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on Object {
      return null;
    }
    if (doc is! YamlMap) return null;
    final flutterSection = doc['flutter'];
    if (flutterSection is! YamlMap) return null;
    final plugin = flutterSection['plugin'];
    if (plugin is! YamlMap) return null;
    final platforms = plugin['platforms'];
    if (platforms is! YamlMap) return null;
    final ios = platforms['ios'];
    if (ios is! YamlMap) return null;
    final pluginClass = ios['pluginClass'];
    return pluginClass is String ? pluginClass : null;
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
  /// Returns every iOS plugin listed in `<projectRoot>/.flutter-plugins-dependencies`.
  /// Returns an empty list (never throws) if the file is missing or has no
  /// `plugins.ios` entries — absence of the file just means no plugins were
  /// ever resolved (e.g. `flutter pub get` not yet run), not a build error;
  /// callers decide whether that's fatal.
  /// Throws [FlutterBuildError] only if the file exists but contains malformed JSON.
  static Future<List<IosPlugin>> discover(String projectRoot) async {
    final file = File(p.join(projectRoot, '.flutter-plugins-dependencies'));
    if (!file.existsSync()) return const [];

    final Object? doc;
    try {
      doc = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw FlutterBuildError('${file.path}: invalid JSON: $e');
    }

    if (doc is! Map) return const [];
    final plugins = doc['plugins'];
    if (plugins is! Map) return const [];
    final iosList = plugins['ios'];
    if (iosList is! List) return const [];

    return [
      for (final entry in iosList)
        if (entry is Map && entry['name'] is String && entry['path'] is String)
          IosPlugin(
            name: entry['name'] as String,
            packageRoot: _resolvePath(entry['path'] as String, projectRoot),
          ),
    ];
  }

  static String _resolvePath(String path, String projectRoot) =>
      p.isAbsolute(path) ? path : p.join(projectRoot, path);
}
