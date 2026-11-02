import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';

/// Result of [AssetCatalogReader.read].
@internal
@immutable
final class AssetCatalogReadResult {
  const AssetCatalogReadResult({
    required this.catalog,
    this.skipped = const [],
    this.diagnostics = const [],
  });

  final AssetCatalog catalog;

  /// Directory names of asset types xcross does not support (`X.symbolset`).
  final List<String> skipped;

  /// Human readable problems (malformed `Contents.json`) for warnings.
  final List<String> diagnostics;
}

/// Parses an `.xcassets` directory into an [AssetCatalog] without `actool`.
@internal
final class AssetCatalogReader {
  AssetCatalogReader(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  static const _unsupported = {
    'symbolset',
    'dataset',
    'launchimage',
    'brandassets',
    'imagestack',
    'imagestacklayer',
    'stickers',
    'stickersequence',
    'sticker',
    'complicationset',
    'spritesheet',
    'texture',
    'textureset',
    'cubetextureset',
    'mipmapset',
    'gcdashboardimage',
    'gcleaderboard',
    'gcleaderboardset',
  };

  AssetCatalogReadResult read(String xcassetsPath) {
    final root = paths.absolute(xcassetsPath);
    final images = <ImageSetAsset>[];
    final colors = <ColorSetAsset>[];
    final icons = <AppIconSetAsset>[];
    final skipped = <String>[];
    final diagnostics = <String>[];
    _walk(root, '', images, colors, icons, skipped, diagnostics);
    return AssetCatalogReadResult(
      catalog: AssetCatalog(
        path: root,
        imageSets: images,
        colorSets: colors,
        appIconSets: icons,
      ),
      skipped: skipped,
      diagnostics: diagnostics,
    );
  }

  void _walk(
    String dir,
    String prefix,
    List<ImageSetAsset> images,
    List<ColorSetAsset> colors,
    List<AppIconSetAsset> icons,
    List<String> skipped,
    List<String> diagnostics,
  ) {
    final List<FileSystemEntity> children;
    try {
      children = fileSystem.directory(dir).listSync();
    } on FileSystemException catch (e) {
      diagnostics.add('Cannot list $dir: ${e.message}');
      return;
    }
    final subdirs = children.whereType<Directory>().map((d) => d.path).toList()
      ..sort((a, b) => paths.basename(a).compareTo(paths.basename(b)));
    for (final sub in subdirs) {
      final base = paths.basename(sub);
      final ext = paths.extension(base).replaceFirst('.', '');
      final stem = paths.basenameWithoutExtension(base);
      switch (ext) {
        case 'imageset':
          _readSet(sub, prefix + stem, diagnostics, (json, name) {
            images.add(ImageSetAsset(name: name, images: _images(sub, json)));
          });
        case 'colorset':
          _readSet(sub, prefix + stem, diagnostics, (json, name) {
            colors.add(ColorSetAsset(name: name, colors: _colors(json)));
          });
        case 'appiconset':
          _readSet(sub, prefix + stem, diagnostics, (json, name) {
            icons.add(AppIconSetAsset(name: name, images: _icons(sub, json)));
          });
        default:
          if (_unsupported.contains(ext)) {
            skipped.add(base);
          } else if (ext.isEmpty || !base.contains('.')) {
            var childPrefix = prefix;
            final contents = _json(sub, diagnostics);
            final props = contents?['properties'];
            if (props is Map && props['provides-namespace'] == true) {
              childPrefix = '$prefix$base/';
            }
            _walk(
              sub,
              childPrefix,
              images,
              colors,
              icons,
              skipped,
              diagnostics,
            );
          }
      }
    }
  }

  Map<String, Object?>? _json(String dir, List<String> diagnostics) {
    final file = fileSystem.file(paths.join(dir, 'Contents.json'));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(
        file.readAsStringSync().replaceFirst('\uFEFF', ''),
      );
      if (decoded is Map<String, Object?>) return decoded;
      diagnostics.add('${file.path}: not a JSON object');
    } on Object catch (e) {
      diagnostics.add('${file.path}: $e');
    }
    return null;
  }

  void _readSet(
    String dir,
    String name,
    List<String> diagnostics,
    void Function(Map<String, Object?> json, String name) onRead,
  ) {
    final json = _json(dir, diagnostics);
    if (json == null) {
      if (!fileSystem.file(paths.join(dir, 'Contents.json')).existsSync()) {
        diagnostics.add('$dir: missing Contents.json');
      }
      return;
    }
    try {
      onRead(json, name);
    } on Object catch (e) {
      diagnostics.add('$dir: $e');
    }
  }

  Iterable<Map<String, Object?>> _entries(
    Map<String, Object?> json,
    String key,
  ) {
    final list = json[key];
    if (list is! List) return const [];
    return list.whereType<Map<String, Object?>>();
  }

  /// Returns null if the entry is a high-contrast variant to skip.
  ({bool skip, AssetAppearance appearance}) _appearance(
    Map<String, Object?> entry,
  ) {
    var appearance = AssetAppearance.any;
    final list = entry['appearances'];
    if (list is List) {
      for (final a in list.whereType<Map<String, Object?>>()) {
        final key = a['appearance'];
        final value = a['value'];
        if (key == 'luminosity') {
          appearance = switch (value) {
            'dark' => AssetAppearance.dark,
            'light' => AssetAppearance.light,
            'tinted' => AssetAppearance.tinted,
            _ => appearance,
          };
        } else if (key == 'contrast') {
          return (skip: true, appearance: appearance);
        }
      }
    }
    return (skip: false, appearance: appearance);
  }

  String? _existing(String dir, Map<String, Object?> entry) {
    final name = entry['filename'];
    if (name is! String || name.isEmpty) return null;
    final path = paths.join(dir, name);
    return fileSystem.file(path).existsSync() ? path : null;
  }

  int _scale(Object? value) {
    if (value is String) {
      return int.tryParse(value.replaceAll('x', '')) ?? 1;
    }
    return 1;
  }

  List<ImageSetEntry> _images(String dir, Map<String, Object?> json) => [
    for (final e in _entries(json, 'images'))
      if (_existing(dir, e) case final path?)
        if (_appearance(e) case (:final skip, :final appearance) when !skip)
          ImageSetEntry(
            filePath: path,
            scale: _scale(e['scale']),
            idiom:
                AssetIdiom.tryParse(e['idiom'] as String?) ??
                AssetIdiom.universal,
            appearance: appearance,
          ),
  ];

  List<AppIconEntry> _icons(String dir, Map<String, Object?> json) => [
    for (final e in _entries(json, 'images'))
      if (_existing(dir, e) case final path?)
        if (_appearance(e) case (:final skip, :final appearance) when !skip)
          if (_iconSize(e['size']) case final size?)
            AppIconEntry(
              filePath: path,
              size: size,
              scale: _scale(e['scale']),
              idiom:
                  AssetIdiom.tryParse(e['idiom'] as String?) ??
                  AssetIdiom.universal,
              platform: e['platform'] as String?,
              appearance: appearance,
            ),
  ];

  double? _iconSize(Object? value) =>
      value is String ? double.tryParse(value.split('x').first) : null;

  List<ColorSetEntry> _colors(Map<String, Object?> json) => [
    for (final e in _entries(json, 'colors'))
      if (e['color'] case final Map<String, Object?> color)
        if (_parseColor(color) case final parsed?)
          if (_appearance(e) case (:final skip, :final appearance) when !skip)
            ColorSetEntry(
              color: parsed,
              idiom:
                  AssetIdiom.tryParse(e['idiom'] as String?) ??
                  AssetIdiom.universal,
              appearance: appearance,
            ),
  ];

  AssetColor? _parseColor(Map<String, Object?> color) {
    final comps = color['components'];
    if (comps is! Map) return null;
    final space =
        AssetColorSpace.tryParse(color['color-space'] as String?) ??
        AssetColorSpace.srgb;
    double? c(String key) => _component(comps[key]);
    final rawAlpha = comps['alpha'];
    final alpha =
        rawAlpha is String && (rawAlpha.trim() == '1' || rawAlpha.trim() == '0')
        ? double.parse(rawAlpha)
        : c('alpha') ?? 1;
    final white = c('white');
    if (white != null) {
      return AssetColor(
        red: white,
        green: white,
        blue: white,
        alpha: alpha,
        colorSpace: color['color-space'] == null
            ? AssetColorSpace.grayGamma22
            : space,
      );
    }
    final r = c('red');
    final g = c('green');
    final b = c('blue');
    if (r == null || g == null || b == null) return null;
    return AssetColor(
      red: r,
      green: g,
      blue: b,
      alpha: alpha,
      colorSpace: space,
    );
  }

  /// `"0.200"` float, `"0x33"` hex byte, `"51"` integer byte.
  double? _component(Object? value) {
    if (value is num) {
      return value is int ? value / 255 : value.toDouble();
    }
    if (value is! String) return null;
    final text = value.trim();
    if (text.startsWith('0x') || text.startsWith('0X')) {
      final n = int.tryParse(text.substring(2), radix: 16);
      return n == null ? null : n / 255;
    }
    if (text.contains('.')) return double.tryParse(text);
    final n = int.tryParse(text);
    return n == null ? null : n / 255;
  }
}
