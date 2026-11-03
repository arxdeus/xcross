import 'package:meta/meta.dart';

/// One `flutter: assets:` entry: a bare path or `{path, flavors, platforms,
/// transformers}`. A trailing `/` names a directory (non-recursive).
@internal
final class PubspecAsset {
  const PubspecAsset({
    required this.path,
    this.flavors = const {},
    this.platforms = const {},
    this.hasTransformers = false,
  });

  /// File or directory, relative to `pubspec.yaml`.
  final String path;
  final Set<String> flavors;
  final Set<String> platforms;
  final bool hasTransformers;

  bool get isDirectory => path.endsWith('/');

  /// Same selection rule as flutter_tools' `_Asset.matchesFlavor` and
  /// `matchesPlatform`.
  bool appliesTo({required String? flavor, required String platform}) =>
      (flavors.isEmpty || (flavor != null && flavors.contains(flavor))) &&
      (platforms.isEmpty || platforms.contains(platform));
}
