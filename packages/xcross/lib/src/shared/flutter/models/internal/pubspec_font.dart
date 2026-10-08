import 'package:meta/meta.dart';

/// One `flutter: fonts:` asset entry, e.g. `{asset: fonts/Foo.ttf, weight:
/// 700}`.
@internal
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
@internal
final class PubspecFontFamily {
  const PubspecFontFamily({required this.family, required this.fonts});

  final String family;
  final List<PubspecFontAsset> fonts;

  Map<String, Object> get descriptor => {
    'family': family,
    'fonts': [for (final font in fonts) font.descriptor],
  };
}
