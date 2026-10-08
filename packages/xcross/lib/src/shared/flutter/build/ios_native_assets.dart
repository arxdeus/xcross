import 'dart:convert';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/build/internal/flutter_tool_workspace.dart';
import 'package:xcross/src/shared/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/shared/flutter/build/internal/native_assets_hook_discovery.dart';
import 'package:xcross/src/shared/flutter/build/internal/native_assets_manifest.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/models/flutter/dart_defines.dart';

/// Native code assets produced by Flutter's Dart build-hook pipeline.
@internal
@immutable
final class IosNativeAssetsBuildResult {
  const IosNativeAssetsBuildResult({
    required this.manifestPath,
    required this.frameworks,
  });

  final String manifestPath;
  final List<String> frameworks;
}

/// Runs Flutter's iOS asset assembly to collect native assets and notices
/// without replacing xcross's custom kernel/App.framework build.
@internal
final class IosNativeAssetsBuilder<T extends PlatformHostInterface> {
  IosNativeAssetsBuilder({
    required this.engineCache,
    required this.hooks,
    required this.nativeAssetFrameworks,
    required this.renderer,
    required this.runner,
    required this.tools,
    required this.projectRoot,
    required this.flutterRoot,
    required this.deploymentTarget,
    this.entrypoint = 'lib/main.dart',
    this.dartDefines = const [],
    this.flavor,
  }) {
    if (flutterRoot != engineCache.flutterRoot ||
        !identical(target, tools.target) ||
        !identical(host, runner.host) ||
        !identical(host, renderer.host) ||
        !identical(host, tools.host) ||
        !identical(runner, nativeAssetFrameworks.runner) ||
        !identical(host.fileSystem, nativeAssetFrameworks.fileSystem) ||
        !identical(host.paths.context, nativeAssetFrameworks.paths)) {
      throw ArgumentError(
        'Native assets collaborators must share one target and host',
      );
    }
  }

  final NativeAssetsHookDiscovery hooks;
  final NativeAssetFrameworks<T> nativeAssetFrameworks;
  final IosEngineCache<T> engineCache;
  final AppleToolShimRenderer<T> renderer;
  IosTarget<T> get target => engineCache.target;
  T get host => target.host;
  final ProcessRunner<T> runner;
  final AppleToolShimResolver<T> tools;
  final String projectRoot;
  final String flutterRoot;
  final IosDeploymentTarget deploymentTarget;
  final String entrypoint;
  final List<String> dartDefines;
  final String? flavor;

  Future<IosNativeAssetsBuildResult> build() async {
    final output = engineCache.targetPolicy.buildDirectory(
      projectRoot,
      'xcross-native-assets',
    );
    final outputDirectory = host.fileSystem.directory(output);
    // Deliberately not cleared. `flutter assemble` is incremental and treats
    // this directory as its output set, so deleting it forced every target,
    // including every native build hook, to re-run on each build.
    await outputDirectory.create(recursive: true);

    if (!await hooks.hasBuildHooks(projectRoot)) {
      final withoutHooks = await _buildBundleWithoutHooks(output);
      return withoutHooks;
    }

    final config = await tools.resolve(deploymentTarget.version);
    final forwarder = await tools.resolveNativeAssetToolForwarder(
      tools.executable,
    );
    await engineCache.ensureArtifactsAvailable();
    final workspace = await FlutterToolWorkspace.create(
      flutterRoot: flutterRoot,
      engineCache: engineCache,
    );
    final shims = await host.fileSystem
        .directory(host.paths.temporaryRoot)
        .createTemp('xcross-apple-tools-');
    try {
      await installAppleToolShims(
        shims.path,
        config,
        renderer: renderer,
        toolForwarderExecutable: forwarder,
      );
      await _runFlutterAssemble(output, shims.path, config.iosSdk, workspace);
    } finally {
      try {
        await shims.delete(recursive: true);
      } finally {
        await workspace.dispose();
      }
    }

    final manifest = host.paths.context.join(
      output,
      'App.framework',
      'flutter_assets',
      'NativeAssetsManifest.json',
    );
    if (!host.fileSystem.file(manifest).existsSync()) {
      throw FlutterBuildError(
        'Flutter native-assets build did not produce $manifest',
      );
    }

    final manifestFile = host.fileSystem.file(manifest);
    final original = await manifestFile.readAsString();
    final normalized = normalizeIosNativeAssetsManifest(original);
    if (normalized != original) await manifestFile.writeAsString(normalized);

    final sources = nativeAssetFrameworks.collect(
      normalized,
      output,
      projectRoot: projectRoot,
    );
    final frameworks = await nativeAssetFrameworks.stage(sources, output);
    await nativeAssetFrameworks.thin(frameworks, lipo: config.lipo);
    if (engineCache.mode.isPrecompiled) await _strip(frameworks);
    await nativeAssetFrameworks.align(frameworks);
    await nativeAssetFrameworks.normalize(frameworks);

    return IosNativeAssetsBuildResult(
      manifestPath: manifest,
      frameworks: frameworks,
    );
  }

  Future<IosNativeAssetsBuildResult> _buildBundleWithoutHooks(
    String output,
  ) async {
    await engineCache.ensureArtifactsAvailable();
    final workspace = await FlutterToolWorkspace.create(
      flutterRoot: flutterRoot,
      engineCache: engineCache,
    );
    final assets = host.paths.context.join(
      output,
      'App.framework',
      'flutter_assets',
    );
    try {
      await runner.runChecked(
        workspace.dart,
        [workspace.flutterToolsSnapshot, ...assembleArguments(output: assets)],
        workingDirectory: projectRoot,
        environment: {'FLUTTER_ROOT': workspace.flutterRoot},
        inheritStdio: runner.log.isVerbose,
        label: 'Flutter asset bundle',
      );
    } finally {
      await workspace.dispose();
    }

    final manifest = host.paths.context.join(
      assets,
      'NativeAssetsManifest.json',
    );
    if (!host.fileSystem.file(manifest).existsSync()) {
      throw FlutterBuildError('Flutter asset bundle did not produce $manifest');
    }
    return IosNativeAssetsBuildResult(
      manifestPath: manifest,
      frameworks: const [],
    );
  }

  /// Strips local and debug symbols from code assets of profile and release
  /// builds, as flutter_tools does (`strip -x -S`).
  Future<void> _strip(Iterable<String> frameworks) async {
    final strip = await tools.toolchain.locateLlvmTool('llvm-strip');
    if (strip == null) {
      runner.log.logWarn(
        'llvm-strip not found; native asset frameworks keep their symbols.',
      );
      return;
    }
    for (final framework in frameworks) {
      final binary = host.paths.context.join(
        framework,
        host.paths.context.basenameWithoutExtension(framework),
      );
      await runner.runChecked(strip, [
        '-x',
        '-S',
        binary,
        '-o',
        binary,
      ], label: 'llvm-strip');
    }
  }

  /// Flutter assemble inputs shared by the bundle and native-hook targets.
  /// Using assemble also preserves explicit FLUTTER_APP_FLAVOR overrides,
  /// which the higher-level `build bundle` command rejects.
  @visibleForTesting
  List<String> assembleArguments({required String output, String? iosSdk}) => [
    'assemble',
    '--no-version-check',
    '-o',
    output,
    '-dTargetPlatform=ios',
    '-dBuildMode=${engineCache.mode.name}',
    '-dIosArchs=arm64',
    if (iosSdk != null) '-dSdkRoot=$iosSdk',
    '-dTargetFile=$entrypoint',
    '-dIosDeploymentTarget=${deploymentTarget.version}',
    '-dDartDefines=${DartDefines.withFlavor(dartDefines, flavor).map((define) => base64.encode(utf8.encode(define))).join(',')}',
    if (iosSdk != null)
      'debug_ios_bundle_flutter_assets'
    else
      'copy_flutter_bundle',
  ];

  Future<void> _runFlutterAssemble(
    String output,
    String shimDirectory,
    String iosSdk,
    FlutterToolWorkspace workspace,
  ) async {
    await runner.runChecked(
      workspace.dart,
      [
        workspace.flutterToolsSnapshot,
        ...assembleArguments(output: output, iosSdk: iosSdk),
      ],
      workingDirectory: projectRoot,
      // Flutter's hook runner sanitizes its environment. Tool shims therefore
      // embed resolved paths rather than reading xcross-specific variables.
      environment: {
        'FLUTTER_ROOT': workspace.flutterRoot,
        'PATH': _prependPath(
          shimDirectory,
          runner.environmentValue(runner.effectiveEnvironment, 'PATH'),
        ),
      },
      inheritStdio: runner.log.isVerbose,
      label: 'Flutter native assets',
    );
  }

  String _prependPath(String directory, String? base) =>
      host.environment.joinPathList([
        directory,
        if (base != null && base.isNotEmpty)
          ...host.environment.splitPathList(base),
      ]);
}
