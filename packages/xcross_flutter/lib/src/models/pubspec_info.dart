import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross_flutter/src/errors.dart';
import 'package:yaml/yaml.dart';

/// One `flutter: fonts:` asset entry, e.g. `{asset: fonts/Foo.ttf, weight:
/// 700}`.
final class PubspecFontAsset {
  const PubspecFontAsset({required this.asset, this.weight, this.style});

  /// Path to the font file, relative to `pubspec.yaml`.
  final String asset;
  final int? weight;
  final String? style;

  /// `FontManifest.json` entry shape.
  Map<String, Object> get descriptor => {
    'asset': asset,
    'weight': ?weight,
    'style': ?style,
  };
}

/// One `flutter: fonts:` family entry, e.g. `{family: Foo, fonts: [...]}`.
final class PubspecFontFamily {
  const PubspecFontFamily({required this.family, required this.fonts});

  final String family;
  final List<PubspecFontAsset> fonts;

  Map<String, Object> get descriptor => {
    'family': family,
    'fonts': [for (final font in fonts) font.descriptor],
  };
}

/// Relevant fields read from a Flutter project's `pubspec.yaml`.
final class PubspecInfo {
  const PubspecInfo({
    required this.name,
    required this.usesMaterialDesign,
    this.assets = const [],
    this.fonts = const [],
  });

  /// Sync so it can be used from a constructor initializer list.
  factory PubspecInfo.loadSync(String projectRoot) {
    final doc = _loadYamlMap(projectRoot);
    final name = _valueOf<String>(doc['name']);
    if (name == null) {
      throw FlutterBuildError('pubspec.yaml: missing "name"');
    }
    final flutter = _valueOf<YamlMap>(doc['flutter']);
    return PubspecInfo(
      name: name,
      usesMaterialDesign: flutter?['uses-material-design'] == true,
      assets: _parseAssets(flutter?['assets']),
      fonts: _parseFonts(flutter?['fonts']),
    );
  }

  /// The package/app name (`name:` key).
  final String name;

  /// Whether `flutter: uses-material-design: true` is set (controls bundling of
  /// `MaterialIcons-Regular.otf`).
  final bool usesMaterialDesign;

  /// `flutter: assets:` entries, e.g. `assets/data.json` or `assets/images/`
  /// (trailing slash = directory, non-recursive).
  final List<String> assets;

  /// `flutter: fonts:` entries.
  final List<PubspecFontFamily> fonts;

  static YamlMap _loadYamlMap(String projectRoot) {
    final file = File(p.join(projectRoot, 'pubspec.yaml'));
    if (!file.existsSync()) {
      throw FlutterBuildError('pubspec.yaml not found in $projectRoot');
    }
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on Object catch (e) {
      // YamlException is a FormatException, not a FlutterBuildError — rethrow
      // so the CLI reports `error: <msg>` instead of dying with a stack trace.
      throw FlutterBuildError('pubspec.yaml: $e');
    }
    if (doc is! YamlMap) {
      throw FlutterBuildError('pubspec.yaml: invalid document');
    }
    return doc;
  }

  /// `assets:` entries are either bare path strings or `{path: ..., flavor:
  /// ...}` maps. Flavor/platform filtering isn't implemented — such assets are
  /// always bundled (over-inclusion is harmless; under-inclusion isn't).
  static List<String> _parseAssets(Object? node) {
    if (node is! YamlList) return const [];
    return [
      for (final entry in node)
        if (entry is String)
          entry
        else if (entry is YamlMap)
          ?_valueOf<String>(entry['path']),
    ];
  }

  static List<PubspecFontFamily> _parseFonts(Object? node) {
    if (node is! YamlList) return const [];
    return [
      for (final entry in node)
        if (entry is YamlMap)
          if (_valueOf<String>(entry['family']) case final family?)
            if (_parseFontAssets(entry['fonts']) case final fonts
                when fonts.isNotEmpty)
              PubspecFontFamily(family: family, fonts: fonts),
    ];
  }

  static List<PubspecFontAsset> _parseFontAssets(Object? node) {
    if (node is! YamlList) return const [];
    return [
      for (final font in node)
        if (font is YamlMap)
          if (_valueOf<String>(font['asset']) case final asset?)
            PubspecFontAsset(
              asset: asset,
              weight: _valueOf<int>(font['weight']),
              style: _valueOf<String>(font['style']),
            ),
    ];
  }

  /// YAML nodes are dynamically typed; keep the "right type or absent" checks
  /// in one place instead of repeating `is T ? as T : null`.
  static T? _valueOf<T>(Object? node) => node is T ? node : null;
}
