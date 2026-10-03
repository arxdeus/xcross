import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/flutter/build/app_extension_builder.dart';
import 'package:xcross/src/flutter/build/internal/runner_binary.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_native_assets.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';

final class FlutterBuildRequest<T extends PlatformHostInterface> {
  FlutterBuildRequest({
    required this.runtime,
    required this.projectRoot,
    required this.bundleId,
    required this.options,
    this.swiftPmArtifactJunctionCapability = false,
    this.packageLocalArtifactJunctionCapability = false,
    this.artifactJunctionCapabilityResolver,
  }) : appName = runtime.pubspecs.loadSync(projectRoot).name,
       versions = runtime.versions.resolve(
         projectRoot,
         buildName: options.buildName,
         buildNumber: options.buildNumber,
       );
  final FlutterBuildRuntime<T> runtime;
  final String projectRoot;
  final String appName;
  final IosBundleVersions versions;
  final String bundleId;
  final FlutterBuildOptions options;
  final bool swiftPmArtifactJunctionCapability;
  final bool packageLocalArtifactJunctionCapability;
  final ArtifactJunctionCapabilityResolver? artifactJunctionCapabilityResolver;
}

final class FlutterBuildContext<T extends PlatformHostInterface> {
  FlutterBuildContext({required this.request, required this.flutterRoot})
    : deploymentTarget = request.runtime.deployments.resolve(
        request.projectRoot,
        platform: request.runtime.target.buildPlatform,
      ),
      appName = request.appName,
      versions = request.versions;
  final FlutterBuildRequest<T> request;
  final String flutterRoot;
  final IosDeploymentTarget deploymentTarget;
  final String appName;
  final IosBundleVersions versions;
  FlutterBuildRuntime<T> get runtime => request.runtime;
  String get projectRoot => request.projectRoot;
  String get bundleId => request.bundleId;
  FlutterBuildOptions get options => request.options;
}

final class FlutterCompiledArtifacts {
  const FlutterCompiledArtifacts({
    required this.appFramework,
    required this.nativeAssets,
    this.plugins,
  });
  final String appFramework;
  final IosNativeAssetsBuildResult nativeAssets;
  final GeneratedPluginsBuildResult? plugins;
}

final class FlutterLinkedArtifacts {
  const FlutterLinkedArtifacts({
    required this.compiled,
    required this.runner,
    required this.extensions,
  });
  final FlutterCompiledArtifacts compiled;
  final RunnerBinary runner;
  final List<BuiltAppExtension> extensions;
}

abstract interface class FlutterResolveStep<T extends PlatformHostInterface> {
  Future<FlutterBuildContext<T>> resolve(FlutterBuildRequest<T> request);
}

abstract interface class FlutterCompileStep<T extends PlatformHostInterface> {
  Future<FlutterCompiledArtifacts> compile();
}

abstract interface class FlutterLinkStep<T extends PlatformHostInterface> {
  Future<FlutterLinkedArtifacts> link(FlutterCompiledArtifacts compiled);
}

abstract interface class FlutterAssembleStep<T extends PlatformHostInterface> {
  Future<String> assemble(FlutterLinkedArtifacts linked);
}
