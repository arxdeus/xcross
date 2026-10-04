import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/flutter/build/flutter_notice_artifact.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_native_assets.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/flutter/flutter_assets_compiler.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/flutter_kernel_compiler.dart';

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
        engineCache: runtime.engineCache(flutterRoot),
        renderer: runtime.toolShimRenderer,
        projectRoot: projectRoot,
        flutterRoot: flutterRoot,
        deploymentTarget: deploymentTarget,
        entrypoint: options.target,
        dartDefines: options.dartDefines,
        flavor: options.flavor,
      ).build(),
    );
    copyFlutterNoticeArtifact(
      sourceFlutterAssetsDirectory: p.dirname(nativeAssets.manifestPath),
      destinationFlutterAssetsDirectory: p.join(appFramework, 'flutter_assets'),
    );
    await runtime.host.fileSystem
        .file(nativeAssets.manifestPath)
        .copy(
          p.join(appFramework, 'flutter_assets', 'NativeAssetsManifest.json'),
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
    final assembleOut = _buildDirectory('xcross-flutter-debug');
    final assembleDir = runtime.host.fileSystem.directory(assembleOut);
    if (assembleDir.existsSync()) await assembleDir.delete(recursive: true);
    await assembleDir.create(recursive: true);

    return FlutterDebugBundler(
      runtime: runtime,
      assets: FlutterAssetsCompiler(
        paths: runtime.host.paths.context,
        fileSystem: runtime.host.fileSystem,
        projectRoot: projectRoot,
        flutterRoot: flutterRoot,
      ),
      kernel: FlutterKernelCompiler(
        runtime: runtime,
        registrant: DartPluginRegistrant(runtime.host.fileSystem),
        plugins: PluginDiscovery(runtime.host.fileSystem),
        projectRoot: projectRoot,
        flutterRoot: flutterRoot,
        entrypoint: options.target,
        dartDefines: options.dartDefines,
        flavor: options.flavor,
      ),
      projectRoot: projectRoot,
      flutterRoot: flutterRoot,
      outputDir: assembleOut,
      deploymentTarget: deploymentTarget,
      entrypoint: options.target,
      dartDefines: options.dartDefines,
      flavor: options.flavor,
    ).build();
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

    final xcframework = runtime.engineCache(flutterRoot).flutterXcframework;
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
    return runtime.plugins.build(
      projectRoot: projectRoot,
      workspace: workspace,
      plugins: spmPlugins,
      flutterXcframework: xcframework,
      deploymentTarget: deploymentTarget,
      verbose: verbose,
      swiftPmArtifactJunctionCapability: capabilities.swiftPmArtifact,
      packageLocalArtifactJunctionCapability: capabilities.packageLocalArtifact,
    );
  }
}
