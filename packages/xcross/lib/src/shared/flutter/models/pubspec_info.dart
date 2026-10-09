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

  /// [version] when it is a valid semantic version, as flutter_tools requires
  /// (`FlutterManifest.appVersion`); `null` otherwise.
  String? get appVersion => switch (version) {
    final version? when _semver.hasMatch(version) => version,
    _ => null,
  };

  /// Build name flutter_tools derives from [appVersion]: the part before `+`.
  String? get buildName => appVersion?.split('+').first;

  /// Build number flutter_tools derives from [appVersion]: the part after
  /// `+`.
  String? get buildNumber {
    final parts = appVersion?.split('+');
    return parts != null && parts.length > 1 ? parts[1] : null;
  }

  /// flutter_tools' hint for a `version:` that is not a semantic version.
  static String invalidVersionHint(String version) =>
      'Invalid version $version found, default value will be used.\n'
      'In pubspec.yaml, a valid version should look like: '
      'build-name+build-number.\n'
      'In iOS, build-name is used as CFBundleShortVersionString while '
      'build-number used as CFBundleVersion.';

  /// `package:pub_semver`'s complete version pattern.
  static final _semver = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)'
    r'(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?'
    r'(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$',
  );

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
