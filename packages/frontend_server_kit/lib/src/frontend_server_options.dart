/// Paths and flags needed to spawn a persistent `frontend_server` process.
class FrontendServerOptions {
  const FrontendServerOptions({
    required this.dart,
    required this.frontendServer,
    required this.sdkRoot,
    required this.packageConfig,
    required this.entrypoint,
    required this.outputDill,
    this.dartDefines = const [],
    this.target = 'flutter',
    this.trackWidgetCreation = true,
    this.initializeFromDill,
    this.onTrace,
  });

  /// Path to the `dart` (or `dartaotruntime`) executable.
  final String dart;

  /// Path to the `frontend_server` snapshot or AOT kernel.
  final String frontendServer;

  /// SDK root passed to `frontend_server --sdk-root` (e.g. Flutter patched SDK).
  final String sdkRoot;

  /// Path to `.dart_tool/package_config.json`.
  final String packageConfig;

  /// Dart entrypoint file (absolute path).
  final String entrypoint;

  /// Output `.dill` path for incremental compilation.
  final String outputDill;

  /// Merged `--dart-define` values as `KEY=VALUE` strings.
  final List<String> dartDefines;

  /// Kernel target (`flutter`, `vm`, …).
  final String target;

  /// Whether to pass `--track-widget-creation`.
  final bool trackWidgetCreation;

  /// Optional warm-start dill for `--initialize-from-dill`.
  final String? initializeFromDill;

  /// Optional trace logger (e.g. CLI verbose output).
  final void Function(String message)? onTrace;
}
