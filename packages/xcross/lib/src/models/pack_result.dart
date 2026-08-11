enum PackOutputKind { app, framework }

final class PackResult {
  const PackResult({
    required this.outputPath,
    required this.bundleId,
    this.kind = PackOutputKind.app,
  });

  final String outputPath;
  final String bundleId;
  final PackOutputKind kind;

  String get appPath {
    if (kind != PackOutputKind.app) {
      throw StateError('PackResult is a framework, not an app');
    }
    return outputPath;
  }
}
