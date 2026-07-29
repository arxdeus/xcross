import 'package:meta/meta.dart';

/// Paths needed to drive Flutter hot reload, shared by [CoreDeviceLauncher]
/// and [HotReloadController].
@immutable
class HotReloadConfig {
  const HotReloadConfig({
    required this.dart,
    required this.frontendServer,
    required this.sdkRoot,
    required this.packageConfig,
    required this.entrypoint,
    required this.projectRoot,
    required this.outputDill,
    this.dartDefines = const [],
    this.verbose = false,
  });

  /// Path to the `dart` (or `dartaotruntime`) executable.
  final String dart;

  /// Path to the `frontend_server` snapshot or AOT kernel.
  final String frontendServer;

  /// Flutter engine SDK root passed to `frontend_server --sdk-root`.
  final String sdkRoot;

  /// Path to `.dart_tool/package_config.json`.
  final String packageConfig;

  /// Dart entrypoint file (absolute path).
  final String entrypoint;

  /// Flutter project root directory.
  final String projectRoot;

  /// Output `.dill` path for incremental compilation.
  final String outputDill;

  /// Merged `--dart-define` values as `KEY=VALUE` strings.
  final List<String> dartDefines;

  /// Whether to emit verbose timing logs.
  final bool verbose;
}
