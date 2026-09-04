import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/cli/ide/xcross_executable.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/config/config.dart';
import 'package:xcross/src/dap/internal/dap_router.dart';
import 'package:xcross/src/dap/xcross_dap.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';

/// Process-global configuration context shared by the CLI and xcross internals.
///
/// A missing file intentionally produces a legacy context. A present file
/// overlays roots, tools, toolchain directories, and allowlisted environment
/// values onto inherited process behavior.
final class XcrossRuntimeConfig {
  const XcrossRuntimeConfig._({
    required this.config,
    required this.configPath,
    required this.processEnvironment,
  });

  static XcrossRuntimeConfig? _current;
  static Future<XcrossRuntimeConfig>? _initializing;

  final XcrossConfig? config;
  final String? configPath;
  final Map<String, String> processEnvironment;

  bool get isLegacy => config == null;
  bool get isConfigured => config != null;
  XcrossConfigRoots? get roots => config?.roots;
  Map<String, String> get tools => config?.tools ?? const {};

  String? tool(String name) => config?.tool(name);

  /// Configured environment overlay, or the invoking environment in legacy mode.
  Map<String, Object> get environment =>
      config?.environment ?? processEnvironment;

  /// Effective string environment inherited by configured child processes.
  Map<String, String> get childEnvironment =>
      ProcessRunner.configuration?.effectiveChildEnvironment ??
      processEnvironment;

  static XcrossRuntimeConfig get current {
    final value = _current;
    if (value == null) {
      throw StateError('XcrossRuntimeConfig.initialize() has not completed');
    }
    return value;
  }

  static bool get isInitialized => _current != null;

  static Future<XcrossRuntimeConfig> initialize({
    XcrossConfigStore? store,
    Map<String, String>? environment,
    bool? windows,
    String? configDirectory,
  }) {
    final existing = _current;
    if (existing != null) return Future.value(existing);
    return _initializing ??= _initialize(
      store: store,
      environment: environment,
      windows: windows,
      configDirectory: configDirectory,
    );
  }

  static Future<XcrossRuntimeConfig> _initialize({
    XcrossConfigStore? store,
    Map<String, String>? environment,
    bool? windows,
    String? configDirectory,
  }) async {
    final env = Map<String, String>.unmodifiable(
      environment ?? Platform.environment,
    );
    final effectiveStore =
        store ??
        XcrossConfigStore(
          directory: configDirectory,
          environment: env,
          windows: windows,
        );
    try {
      final selected = effectiveStore.selectedFile();
      final value = XcrossRuntimeConfig._(
        config: await effectiveStore.load(),
        configPath: selected?.path,
        processEnvironment: env,
      );
      _apply(value);
      return _current = value;
    } finally {
      _initializing = null;
    }
  }

  static void _apply(XcrossRuntimeConfig runtime) {
    final config = runtime.config;
    // Legacy mode is deliberately a no-op: embedders may already have
    // installed ProcessRunner and root overrides through the pre-config seams.
    if (config == null) return;

    final roots = config.roots;
    final separator = Platform.isWindows ? ';' : ':';
    final childEnvironment = <String, String>{
      ...runtime.processEnvironment,
      for (final entry in config.environment.entries)
        entry.key: switch (entry.value) {
          final String value => value,
          final List<String> paths => [
            ...paths,
            if (runtime.processEnvironment[entry.key] case final inherited?)
              inherited,
          ].join(separator),
          _ => throw StateError('Unsupported environment value: ${entry.key}'),
        },
      if (roots.javaHome case final javaHome?) 'JAVA_HOME': javaHome,
      if (roots.konanData case final konanData?) 'KONAN_DATA_DIR': konanData,
      if (runtime.configPath case final configPath?)
        XcrossConfigStore.selectorVariable: configPath,
    };
    ProcessRunner.configure(
      normalizedTools: config.tools,
      toolchainDirectories: {
        if (config.toolchains.swift case final swift?) 'swift': [swift],
        if (config.toolchains.llvm.isNotEmpty) 'llvm': config.toolchains.llvm,
      },
      effectiveChildEnvironment: childEnvironment,
    );
    DarwinSdk.configureInstallBundleOverride(roots.darwinSdk);
    final flutterEnvironment = switch (config.environment['FLUTTER_ROOT']) {
      final String value => value,
      _ => null,
    };
    FlutterPacker.configureFlutterResolution(
      root: roots.flutterSdk,
      environmentRoot: flutterEnvironment,
      tool: config.tool('flutter'),
      declarative: true,
    );
    ComposeSetupOptions.configureCacheRootOverride(roots.konanData);
    configureXcrossLauncherOverride(
      roots.xcross,
      configPath: runtime.configPath,
      flutterRoot: roots.flutterSdk ?? flutterEnvironment,
    );
    configureAppleToolShimResolution(
      launcher: roots.xcross,
      xcrun: config.tool('xcrun'),
      declarative: false,
    );
    DapRouter.configureFlutterResolution(
      root: roots.flutterSdk,
      environmentRoot: flutterEnvironment,
      tool: config.tool('flutter'),
      declarative: true,
    );
    XcrossDap.configureLauncherOverride(roots.xcross);
  }

  /// Clears global state. Intended only for isolated tests.
  static void resetForTests() {
    _current = null;
    _initializing = null;
    ProcessRunner.resetConfiguration();
    DarwinSdk.resetInstallBundleOverride();
    FlutterPacker.resetFlutterRootOverride();
    ComposeSetupOptions.resetCacheRootOverride();
    resetXcrossLauncherOverride();
    resetAppleToolShimLauncherOverride();
    DapRouter.resetConfiguration();
    XcrossDap.resetLauncherOverride();
  }
}
