import 'package:xcross/src/flutter/models/internal/pubspec_font.dart';

final class PubspecInfo {
  const PubspecInfo({
    required this.name,
    required this.usesMaterialDesign,
    this.assets = const [],
    this.fonts = const [],
    this.dependencies = const [],
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

  /// Package names under `dependencies:` (excluding `dev_dependencies`).
  final List<String> dependencies;
}
