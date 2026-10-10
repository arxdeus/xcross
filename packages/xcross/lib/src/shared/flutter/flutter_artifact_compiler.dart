import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/shared/flutter/build/flutter_aot_snapshotter.dart';
import 'package:xcross/src/shared/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/shared/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_native_assets.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugins.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_assets_compiler.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/flutter_kernel_compiler.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';

@internal
final class FlutterArtifactCompiler<T extends PlatformHostInterface>
    implements FlutterCompileStep<T> {
  FlutterArtifactCompiler(this.context);
  final FlutterBuildContext<T> context;
  FlutterBuildRuntime<T> get runtime => context.runtime;
  String get projectRoot => context.projectRoot;
  FlutterBuildOptions get options => context.options;
  bool get swiftPmArtifactJunctionCapability =>
      context.request.swiftPmArtifactJunctionCapability;
  bool get packageLocalArtifactJunctionCapability =>
      context.request.packageLocalArtifactJunctionCapability;
  ArtifactJunctionCapabilityResolver? get artifactJunctionCapabilityResolver =>
      context.request.artifactJunctionCapabilityResolver;
  String _buildDirectory(String name) =>
      runtime.policy.buildDirectory(projectRoot, name);
  @override
  @override
  Future<FlutterCompiledArtifacts> compile() async {
    final flutterRoot = context.flutterRoot;
    final deploymentTarget = context.deploymentTarget;
    final appFramework = await _buildAppFramework(
      flutterRoot,
      deploymentTarget: deploymentTarget,
    );
    final nativeAssets = await runtime.runner.log.logStep(
      'Building native assets',
      () => IosNativeAssetsBuilder(
        nativeAssetFrameworks: runtime.nativeAssetFrameworks,
        hooks: runtime.nativeAssetHooks,
        runner: runtime.runner,
        tools: runtime.nativeTools,
        engineCache: runtime.engineCache(flutterRoot, mode: options.buildMode),
        renderer: runtime.toolShimRenderer,
        projectRoot: projectRoot,
        flutterRoot: flutterRoot,
        deploymentTarget: deploymentTarget,
        entrypoint: options.target,
        dartDefines: context.dartDefines,
        debugSymbols: runtime.debugSymbols,
      ).build(),
    );
    runtime.notices.copy(
      sourceFlutterAssetsDirectory: runtime.host.paths.context.dirname(
        nativeAssets.manifestPath,
      ),
      destinationFlutterAssetsDirectory: runtime.host.paths.context.join(
        appFramework,
        'flutter_assets',
      ),
    );
    await runtime.host.fileSystem
        .file(nativeAssets.manifestPath)
        .copy(
          runtime.host.fileSystem
              .file(
                runtime.host.paths.context.join(
                  appFramework,
                  'flutter_assets',
                  'NativeAssetsManifest.json',
                ),
              )
              .path,
        );
    final pluginsBuild = await _buildPlugins(
      flutterRoot,
      deploymentTarget: deploymentTarget,
      verbose: runtime.runner.log.isVerbose,
    );
    return FlutterCompiledArtifacts(
      appFramework: appFramework,
      nativeAssets: nativeAssets,
      plugins: pluginsBuild,
    );
  }

  Future<String> _buildAppFramework(
    String flutterRoot, {
    required IosDeploymentTarget deploymentTarget,
  }) async {
    final assembleOut = _buildDirectory(
      options.buildMode.intermediatesDirectory,
    );
    final assembleDir = runtime.host.fileSystem.directory(assembleOut);
    if (assembleDir.existsSync()) await assembleDir.delete(recursive: true);
    await assembleDir.create(recursive: true);

    final mode = options.buildMode;
    final snapshotter = aotSnapshotter();
    final debugBundle = await FlutterDebugBundler(
      runtime: runtime,
      assets: FlutterAssetsCompiler(
        paths: runtime.host.paths.context,
        fileSystem: runtime.host.fileSystem,
        projectRoot: projectRoot,
        flutterRoot: flutterRoot,
        flavor: options.flavor,
      ),
      kernel: FlutterKernelCompiler(
        runtime: runtime,
        registrant: DartPluginRegistrant(
          runtime.host.fileSystem,
          runtime.host.paths.context,
          onWarning: runtime.runner.log.logWarn,
        ),
        projectRoot: projectRoot,
        flutterRoot: flutterRoot,
        entrypoint: options.target,
        dartDefines: context.dartDefines,
        buildMode: mode,
      ),
      projectRoot: projectRoot,
      flutterRoot: flutterRoot,
      outputDir: assembleOut,
      deploymentTarget: deploymentTarget,
      entrypoint: options.target,
      treeShakeIcons: options.shakesIcons,
      snapshotter: snapshotter,
      splitDebugInfo: options.splitDebugInfo,
      obfuscate: options.obfuscate,
    ).build();
    return debugBundle;
  }

  /// Creates the AOT snapshotter from the engine the build uses, or `null`
  /// for debug builds.
  @visibleForTesting
  FlutterAotSnapshotterFactory<T>? aotSnapshotter() {
    final mode = options.buildMode.genSnapshotMode;
    if (mode == null) return null;
    final locate = runtime.aotCompilers;
    if (locate == null) {
      throw FlutterBuildError(
        '${options.buildMode.name} builds need the iOS AOT compiler, which '
        'this xcross host does not provide.',
      );
    }
    return (engineCache) async => FlutterAotSnapshotter(
      runtime: runtime,
      compiler: await locate(
        flutterRoot: engineCache.flutterRoot,
        engineDirectory: engineCache.engineDirectory,
        mode: mode,
      ),
      minimumOsVersion:
          engineCache.engineMinimumOsVersion ??
          FlutterAotSnapshotter.fallbackMinimumOsVersion,
    );
  }

  /// Discover the project's iOS plugins and build the aggregate Swift
  /// Package Manager plugins library, if any exist.
  ///
  /// Returns the built dylibs, or null when there's nothing to build — no
  /// plugins at all, or only CocoaPods-only ones xcross doesn't support (a
  /// warning is logged for those; matching Flutter's own tool, this doesn't
  /// fail the build).
  Future<GeneratedPluginsBuildResult?> _buildPlugins(
    String flutterRoot, {
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
  }) async {
    final plugins = await PluginDiscovery(
      runtime.host.fileSystem,
    ).discover(projectRoot);
    final spmPlugins = <IosPlugin>[];
    for (final plugin in plugins) {
      final dir = plugin.platformDirectoryName;
      if (plugin.usesSwiftPackageManager) {
        spmPlugins.add(plugin);
      } else if (plugin.usesCocoaPods) {
        runtime.runner.log.logWarn(
          'Plugin "${plugin.name}" only ships a CocoaPods podspec '
          '(no $dir/${plugin.name}/Package.swift); its native iOS code will '
          'not be included. xcross only supports Swift Package Manager '
          'plugins.',
        );
      } else if (plugin.declaresNativeIosCode) {
        // The plugin's pubspec claims a native iOS pluginClass, but neither a
        // Package.swift nor a podspec turned up where they were looked for.
        // Staying silent here is what made a dropped plugin present as a black
        // screen: the app launches, then the first method channel call to the
        // missing implementation never returns.
        runtime.runner.log.logWarn(
          'Plugin "${plugin.name}" declares native iOS code but no '
          '$dir/${plugin.name}/Package.swift or $dir/${plugin.name}.podspec '
          'was found under ${plugin.packageRoot}; its plugin channels will '
          'not respond at runtime.',
        );
      }
    }
    if (spmPlugins.isEmpty) return null;

    final xcframework = runtime
        .engineCache(flutterRoot, mode: options.buildMode)
        .flutterXcframework;
    final capabilities =
        await artifactJunctionCapabilityResolver?.call() ??
        (
          swiftPmArtifact: swiftPmArtifactJunctionCapability,
          packageLocalArtifact: packageLocalArtifactJunctionCapability,
        );

    final workspace = SwiftPmWorkspace.forProject(
      projectRoot,
      policy: runtime.policy,
    );
    final builtPlugins = await runtime.plugins.build(
      projectRoot: projectRoot,
      workspace: workspace,
      plugins: spmPlugins,
      flutterXcframework: xcframework,
      deploymentTarget: deploymentTarget,
      verbose: verbose,
      swiftPmArtifactJunctionCapability: capabilities.swiftPmArtifact,
      packageLocalArtifactJunctionCapability: capabilities.packageLocalArtifact,
    );
    return builtPlugins;
  }
}
