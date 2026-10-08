import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/models/internal/pubspec_font.dart';
import 'package:xcross/src/shared/flutter/models/internal/pubspec_shader.dart';

@internal
final class PubspecInfo {
  const PubspecInfo({
    required this.name,
    required this.usesMaterialDesign,
    this.assets = const [],
    this.fonts = const [],
    this.shaders = const [],
    this.dependencies = const [],
    this.version,
  });

  /// The `version:` key, such as `1.0.0+1`.
  final String? version;

  /// Build name flutter_tools derives from [version]: the part before `+`.
  String? get buildName => version?.split('+').first;

  /// Build number flutter_tools derives from [version]: the part after `+`.
  String? get buildNumber {
    final parts = version?.split('+');
    return parts != null && parts.length > 1 ? parts[1] : null;
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

  /// `flutter: shaders:` entries.
  final List<PubspecShader> shaders;

  /// Package names under `dependencies:` (excluding `dev_dependencies`).
  final List<String> dependencies;
}
