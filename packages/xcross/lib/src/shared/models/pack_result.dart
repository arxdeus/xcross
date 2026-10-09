import 'package:meta/meta.dart';

@internal
enum PackOutputKind { app, framework }

@internal
final class PackResult {
  const PackResult({
    required this.outputPath,
    required this.bundleId,
    this.kind = PackOutputKind.app,
    this.projectRoot,
    this.dartDefines = const [],
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

  /// The complete Dart defines the bundle was compiled with, for builders
  /// that compile Dart; incremental recompiles must reuse them.
  final List<String> dartDefines;

  String get appPath {
    if (kind != PackOutputKind.app) {
      throw StateError('PackResult is a framework, not an app');
    }
    return outputPath;
  }
}
