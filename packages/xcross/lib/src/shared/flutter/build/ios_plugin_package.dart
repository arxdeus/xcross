import 'dart:async';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugins.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_destination_publisher.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/foundation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_dependencies.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';
@internal
typedef SwiftPmDependencyRefEvaluator =
    Future<Map<String, String>> Function(
      String packageDirectory, {
      required String? scratchPath,
      required String? binaryArtifactStore,
      required String? binaryArtifactFallback,
      required bool swiftPmArtifactJunctionCapability,
      required bool packageLocalArtifactJunctionCapability,
      required List<SwiftPmPackageDependency> dependencies,
    });

@internal
typedef PrepareSwiftPmBinaryArtifact =
    Future<SwiftPmPreparedBinaryArtifact> Function(
      SwiftPmRemoteBinaryTarget target,
    );
@internal
typedef CreateSwiftPmBinaryAlias =
    Future<void> Function({required String alias, required String target});
@internal
typedef MaterializeSwiftPmBinaryArtifact =
    Future<SwiftPmBinaryArtifactPublication> Function({
      required String source,
      required String destination,
    });

@internal
final class SwiftPmPackageDependency<T extends PlatformHostInterface> {
  const SwiftPmPackageDependency({
    required this.name,
    required this.url,
    required this.identity,
    required this.match,
  });

  final String? name;
  final String url;
  final String identity;
  final String match;
}

@internal
final class SwiftPmBinaryArtifactProvenance<T extends PlatformHostInterface> {
  const SwiftPmBinaryArtifactProvenance({
    required this.packageIdentity,
    required this.target,
    required this.manifestPath,
  });

  final String packageIdentity;
  final SwiftPmRemoteBinaryTarget target;
  final String manifestPath;
}

@internal
final class SwiftPmBinaryAttemptState {
  final Set<String> bootstrapRecovered = {};
  final Set<String> finalRecovered = {};
  final Set<String> copied = {};
}

@internal
final class GeneratedPluginsBuildResult {
  const GeneratedPluginsBuildResult({
    required this.libraryPath,
    required this.dylibPaths,
    required this.modulesDir,
  });
  final String libraryPath;
  final List<String> dylibPaths;
  final String? modulesDir;
}

@internal
typedef ArtifactJunctionCapabilityResolver =
    Future<({bool swiftPmArtifact, bool packageLocalArtifact})> Function();

@internal
final class GeneratedPluginsPackage<T extends PlatformHostInterface> {
  GeneratedPluginsPackage(
    FlutterTargetBuildPolicy<T> policy, {
    required ProcessRunner<T> runner,
    required DarwinSdkRepository<T> sdkRepository,
    required DarwinToolchainResolver<T> toolchain,
    required AppleToolShimResolver<T> tools,
    required SwiftPmHostPolicy hostPolicy,
    required SwiftPmArtifactFileSystem artifactFileSystem,
    required SwiftPmSdkIdentity sdkIdentity,
    required SwiftPmPublicationCoordinator publicationCoordinator,
    required SwiftPmArchiveTransport transport,
    required SwiftPmArtifactCopyPolicy copyPolicy,
    required SwiftPmBuildExecution<T> buildExecution,
    required SwiftPmDependencyPreparation<T> dependencyPreparation,
    required SwiftPmCheckout<T> checkout,
    required SwiftPmCheckoutAttributes checkoutAttributes,
    required SwiftPmCheckoutManifestNormalizer<T> checkoutManifestNormalizer,
    required SwiftPmFoundation<T> foundation,
    required SwiftPmGatePlatform gatePlatform,
  }) : runtime = SwiftPmRuntime(
         policy,
         runner,
         sdkRepository,
         toolchain,
         tools,
         hostPolicy,
         artifactFileSystem,
         sdkIdentity,
         publicationCoordinator,
         transport,
         copyPolicy,
         buildExecution,
         dependencyPreparation,
         checkout,
         checkoutAttributes,
         checkoutManifestNormalizer,
         foundation,
         gatePlatform,
       );
  final SwiftPmRuntime<T> runtime;

  Future<({bool swiftPmArtifact, bool packageLocalArtifact})>
  resolveArtifactJunctionCapabilities({required SwiftPmWorkspace workspace}) =>
      runtime.artifactCapabilities.resolveArtifactJunctionCapabilities(
        workspace: workspace,
      );

  /// Builds the aggregate dylib for the subset of [plugins] that use Swift
  /// Package Manager. Returns null if there is nothing to build.
  ///
  /// [projectRoot]        — Flutter project root (logging context only).
  /// [flutterXcframework] — Path to the real `Flutter.xcframework` (from
  ///                         `IosEngineCache.flutterXcframework`).
  /// [workspace] owns the stable generated-package, scratch, and vendored
  /// dependency directories reused between builds.
  Future<GeneratedPluginsBuildResult?> build({
    required String projectRoot,
    required SwiftPmWorkspace workspace,
    required List<IosPlugin> plugins,
    required String flutterXcframework,
    required IosDeploymentTarget deploymentTarget,
    bool verbose = false,
    String? toolchainIdentity,
    String? sdkIdentity,
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
    ArtifactJunctionCapabilityResolver? artifactJunctionCapabilityResolver,
    SwiftPmDependencyRefEvaluator? evaluateDependencyRefs,
    Future<void> Function(
      String git,
      String url,
      String ref,
      String destination,
    )?
    clonePackage,
  }) => runtime.runner.log.logStep(
    'Building Flutter plugins (Swift Package Manager)',
    () async {
      final outputDir = workspace.packages;
      final spmPlugins = plugins
          .where((plugin) => plugin.usesSwiftPackageManager)
          .toList();
      if (spmPlugins.isEmpty) return null;
      await runtime.hostPolicy.hostEnvironment();
      final capabilities =
          await artifactJunctionCapabilityResolver?.call() ??
          (
            swiftPmArtifact: swiftPmArtifactJunctionCapability,
            packageLocalArtifact: packageLocalArtifactJunctionCapability,
          );

      runtime.runner.log.logTrace(
        'projectRoot=$projectRoot '
        'spmPlugins=${[for (final plugin in spmPlugins) plugin.name]}',
      );

      final targetDebugDir = p.join(
        workspace.scratch,
        deploymentTarget.swiftSdkTriple,
        'debug',
      );
      final fingerprint = await runtime.discovery.incrementalBuildFingerprint(
        plugins: spmPlugins,
        flutterXcframework: flutterXcframework,
        deploymentTarget: deploymentTarget,
        verbose: verbose,
        toolchainIdentity: toolchainIdentity,
        sdkIdentity: sdkIdentity,
      );
      final fingerprintFile = runtime.artifactFileSystem.file(
        p.join(outputDir, '.xcross-build-fingerprint'),
      );
      if (fingerprintFile.existsSync() &&
          await fingerprintFile.readAsString() == fingerprint &&
          runtime.artifactFileSystem
              .file(p.join(targetDebugDir, 'lib$pluginsProductName.dylib'))
              .existsSync()) {
        runtime.runner.log.logTrace('reusing unchanged SwiftPM plugin build');
        return runtime.assembly.discoverAndRewriteDylibs(targetDebugDir);
      }
      final targetDirectory = runtime.artifactFileSystem.directory(
        targetDebugDir,
      );
      if (targetDirectory.existsSync()) {
        await targetDirectory.delete(recursive: true);
      }

      final interopProductsByPlugin = <String, Set<String>>{};

      for (final plugin in spmPlugins) {
        final manifest = await runtime.artifactFileSystem
            .file(p.join(plugin.swiftPackageDir, 'Package.swift'))
            .readAsString();
        final products = SwiftPmManifestDependencies.dependencyProductNames(
          manifest,
        );
        if (products.isNotEmpty) {
          interopProductsByPlugin[plugin.name] = products;
        }
      }
      final interopTargetCandidates = {
        for (final products in interopProductsByPlugin.values) ...products,
      };

      await runtime.workspaceStager.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: spmPlugins,
        flutterXcframework: flutterXcframework,
        copyFlutterXcframework: true,
        vendorDir: workspace.vendor,
        copyPluginPackages: spmPlugins.map((plugin) => plugin.name).toSet(),
        deploymentTarget: deploymentTarget,
        verbose: verbose,
        scratchPath: workspace.scratch,
        dependencyRefsCache: workspace.dependencyRefs,
        binaryArtifactStore: workspace.binaryArtifactStore,
        binaryArtifactFallback: workspace.binaryArtifactFallback,
        swiftPmArtifactJunctionCapability: capabilities.swiftPmArtifact,
        packageLocalArtifactJunctionCapability:
            capabilities.packageLocalArtifact,
        evaluateDependencyRefs: evaluateDependencyRefs,
        clonePackage: clonePackage,
      );

      final pluginsDir = p.join(outputDir, 'Plugins');
      final scratchPath = workspace.scratch;
      final stagedFlutterXcframework = p.join(
        outputDir,
        'Packages',
        flutterFrameworkPackageName,
        'Flutter.xcframework',
      );
      await runtime.buildDriver.runSwiftBuild(
        workspace: workspace,
        pluginsDir: pluginsDir,
        scratchPath: scratchPath,
        flutterXcframework: stagedFlutterXcframework,
        deploymentTarget: deploymentTarget,
        interopTargetCandidates: interopTargetCandidates,
        interopConsumers: {
          for (final plugin in spmPlugins)
            if (interopProductsByPlugin[plugin.name] case final products?)
              p.join(
                outputDir,
                'Packages',
                plugin.name,
                plugin.platformDirectoryName,
                p.basename(plugin.swiftPackageDir),
              ): products,
        },
        swiftPmArtifactJunctionCapability: capabilities.swiftPmArtifact,
        packageLocalArtifactJunctionCapability:
            capabilities.packageLocalArtifact,
      );

      final result = await runtime.assembly.discoverAndRewriteDylibs(
        targetDebugDir,
      );
      await runtime.filesystem.writeStable(fingerprintFile.path, fingerprint);
      return result;
    },
  );
}
