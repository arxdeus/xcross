enum PackOutputKind { app, framework }

final class PackResult {
  const PackResult({
    required this.outputPath,
    required this.bundleId,
    this.kind = PackOutputKind.app,
    this.projectRoot,
  });

  final String outputPath;
  final String bundleId;
  final PackOutputKind kind;

  /// Source root the bundle was built from, when the builder knows it.
  ///
  /// `compose run --watch` needs it to watch the right tree: the CLI's own
  /// working directory is not necessarily the project root (the packer walks
  /// up to find `settings.gradle.kts`), and watching the wrong directory
  /// silently reports "no source changes" forever.
  final String? projectRoot;

  String get appPath {
    if (kind != PackOutputKind.app) {
      throw StateError('PackResult is a framework, not an app');
    }
    return outputPath;
  }
}
