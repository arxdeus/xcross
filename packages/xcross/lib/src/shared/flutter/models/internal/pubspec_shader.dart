import 'package:meta/meta.dart';

/// One `flutter: shaders:` entry: a bare path or `{path, flavors, platforms,
/// transformers}`.
@internal
final class PubspecShader {
  const PubspecShader({
    required this.path,
    this.flavors = const {},
    this.platforms = const {},
    this.hasTransformers = false,
  });

  /// Fragment program source, relative to `pubspec.yaml`.
  final String path;
  final Set<String> flavors;
  final Set<String> platforms;
  final bool hasTransformers;

  /// Same selection rule as flutter_tools' `_Asset.matchesFlavor` and
  /// `matchesPlatform`.
  bool appliesTo({required String? flavor, required String platform}) =>
      (flavors.isEmpty || (flavor != null && flavors.contains(flavor))) &&
      (platforms.isEmpty || platforms.contains(platform));
}
