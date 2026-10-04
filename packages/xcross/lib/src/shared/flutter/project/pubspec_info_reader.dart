import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/models/internal/pubspec_font.dart';
import 'package:xcross/src/shared/flutter/models/pubspec_info.dart';
import 'package:yaml/yaml.dart';

final class PubspecInfoReader {
  PubspecInfoReader(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  PubspecInfo loadSync(String projectRoot) {
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
      dependencies: _parseDependencies(projectRoot, doc['dependencies']),
    );
  }

  YamlMap _loadYamlMap(String projectRoot) {
    final file = fileSystem.file(paths.join(projectRoot, 'pubspec.yaml'));
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

  List<String> _parseDependencies(String projectRoot, Object? node) {
    final direct = node is YamlMap
        ? {
            for (final key in node.keys)
              if (key is String) key,
          }
        : <String>{};
    final lockFile = fileSystem.file(paths.join(projectRoot, 'pubspec.lock'));
    if (!lockFile.existsSync()) return direct.toList();

    final lock = loadYaml(lockFile.readAsStringSync());
    final packages = lock is YamlMap ? lock['packages'] : null;
    if (packages is! YamlMap) return direct.toList();
    return [
      for (final entry in packages.entries)
        if (entry.key is String &&
            entry.value is YamlMap &&
            (entry.value as YamlMap)['dependency'] != 'direct dev')
          entry.key as String,
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
