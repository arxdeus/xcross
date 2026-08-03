import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross_flutter/src/errors.dart';
import 'package:yaml/yaml.dart';

/// One `flutter: fonts:` asset entry, e.g. `{asset: fonts/Foo.ttf, weight: 700}`.
@immutable
class PubspecFontAsset {
  const PubspecFontAsset({required this.asset, this.weight, this.style});

  /// Path to the font file, relative to `pubspec.yaml`.
  final String asset;
  final int? weight;
  final String? style;

  /// `FontManifest.json` entry shape: `{"asset": ..., "weight": ..., "style": ...}`.
  Map<String, Object> get descriptor => {
    'asset': asset,
    if (weight != null) 'weight': weight!,
    if (style != null) 'style': style!,
  };
}

/// One `flutter: fonts:` family entry, e.g. `{family: Foo, fonts: [...]}`.
@immutable
class PubspecFontFamily {
  const PubspecFontFamily({required this.family, required this.fonts});

  final String family;
  final List<PubspecFontAsset> fonts;

  Map<String, Object> get descriptor => {
    'family': family,
    'fonts': [for (final font in fonts) font.descriptor],
  };
}

/// Relevant fields read from a Flutter project's `pubspec.yaml`.
@immutable
class PubspecInfo {
  const PubspecInfo({
    required this.name,
    required this.usesMaterialDesign,
    this.assets = const [],
    this.fonts = const [],
  });

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

  /// Sync so it can be used from a constructor initializer list.
  factory PubspecInfo.loadSync(String projectRoot) {
    final file = File(p.join(projectRoot, 'pubspec.yaml'));
    if (!file.existsSync()) {
      throw FlutterBuildError('pubspec.yaml not found in $projectRoot');
    }
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on Object catch (e) {
      // YamlException is a FormatException, not an FlutterBuildError — rethrow so
      // the CLI reports `error: <msg>` instead of dying with a stack trace.
      throw FlutterBuildError('pubspec.yaml: $e');
    }
    if (doc is! YamlMap) {
      throw FlutterBuildError('pubspec.yaml: invalid document');
    }
    final name = doc['name'];
    if (name is! String) {
      throw FlutterBuildError('pubspec.yaml: missing "name"');
    }
    var usesMaterialDesign = false;
    var assets = const <String>[];
    var fonts = const <PubspecFontFamily>[];
    final flutterSection = doc['flutter'];
    if (flutterSection is YamlMap) {
      usesMaterialDesign = flutterSection['uses-material-design'] == true;
      assets = _parseAssets(flutterSection['assets']);
      fonts = _parseFonts(flutterSection['fonts']);
    }
    return PubspecInfo(
      name: name,
      usesMaterialDesign: usesMaterialDesign,
      assets: assets,
      fonts: fonts,
    );
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
        else if (entry is YamlMap && entry['path'] is String)
          entry['path'] as String,
    ];
  }

  static List<PubspecFontFamily> _parseFonts(Object? node) {
    if (node is! YamlList) return const [];
    final result = <PubspecFontFamily>[];
    for (final entry in node) {
      if (entry is! YamlMap) continue;
      final family = entry['family'];
      final fontsNode = entry['fonts'];
      if (family is! String || fontsNode is! YamlList) continue;
      final assets = <PubspecFontAsset>[
        for (final font in fontsNode)
          if (font is YamlMap && font['asset'] is String)
            PubspecFontAsset(
              asset: font['asset'] as String,
              weight: font['weight'] is int ? font['weight'] as int : null,
              style: font['style'] is String ? font['style'] as String : null,
            ),
      ];
      if (assets.isNotEmpty) {
        result.add(PubspecFontFamily(family: family, fonts: assets));
      }
    }
    return result;
  }
}
