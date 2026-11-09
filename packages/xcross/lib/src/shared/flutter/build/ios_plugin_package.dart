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
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/flutter_staging.dart';
import 'package:xcross/src/shared/flutter/swiftpm/foundation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_dependencies.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_types.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

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
       ) {
    staging = FlutterSwiftPmStaging<T>(runtime, policy);
  }
  final SwiftPmRuntime<T> runtime;

  /// Flutter plugin staging (manifest, registrant, overlays, discovery).
  late final FlutterSwiftPmStaging<T> staging;

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
  /// [workspace] owns the stable generated-package and scratch directories
  /// reused between builds.
  Future<SwiftPmBuildResult?> build({
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
      final pluginIdentities = {
        for (final MapEntry(:key, :value) in flutterPluginSwiftPmIdentities({
          for (final plugin in spmPlugins)
            plugin.name: p.basename(plugin.packageRoot),
        }).entries)
          key.toLowerCase(): value,
      };
      final fingerprint = await staging.discovery.incrementalBuildFingerprint(
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
      final pluginsDylib = runtime.artifactFileSystem.file(
        p.join(targetDebugDir, 'lib$pluginsProductName.dylib'),
      );
      final fingerprintMatches =
          fingerprintFile.existsSync() &&
          await fingerprintFile.readAsString() == fingerprint;
      if (fingerprintMatches && pluginsDylib.existsSync()) {
        runtime.runner.log.logTrace('reusing unchanged SwiftPM plugin build');
        final reused = await runtime.assembly.discoverAndRewriteDylibs(
          targetDebugDir,
          productName: pluginsProductName,
          packageIdentities: pluginIdentities,
        );
        return reused;
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

      Future<void> stage() => staging.workspaceStager.writeGeneratedPackages(
        outputDir: outputDir,
        plugins: spmPlugins,
        flutterXcframework: flutterXcframework,
        copyFlutterXcframework: true,
        copyPluginPackages: spmPlugins.map((plugin) => plugin.name).toSet(),
        deploymentTarget: deploymentTarget,
        verbose: verbose,
        scratchPath: workspace.scratch,
        binaryArtifactStore: workspace.binaryArtifactStore,
        binaryArtifactFallback: workspace.binaryArtifactFallback,
        swiftPmArtifactJunctionCapability: capabilities.swiftPmArtifact,
        packageLocalArtifactJunctionCapability:
            capabilities.packageLocalArtifact,
        sourceFallback: runtime.processPolicy.sourceFallbackActive,
      );
      await stage();

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
        productName: pluginsProductName,
        // Real `Flutter.framework` (not our FlutterFramework binary-target
        // wrapper). Our own aggregate target resolves `import Flutter` via
        // that wrapper's declared package dependency, but individual
        // third-party plugin targets often don't declare any such dependency
        // in their own Package.swift at all; they rely on Xcode's implicit,
        // project-wide framework search paths to make `import Flutter`
        // resolve (verified against a real published plugin: its manifest
        // lists zero dependencies, yet its Swift source does
        // `import Flutter`). The slice is passed as a build-wide framework
        // search path so `<Flutter/Flutter.h>` resolves for C targets too.
        frameworkSearchPaths: [
          staging.flutterPolicy.selectEngineSlice(stagedFlutterXcframework),
        ],
        deploymentTarget: deploymentTarget,
        interopTargetCandidates: interopTargetCandidates,
        interopConsumers: {
          for (final plugin in spmPlugins)
            p.join(
              outputDir,
              'Packages',
              plugin.name,
              plugin.platformDirectoryName,
              p.basename(plugin.swiftPackageDir),
            ): ?interopProductsByPlugin[plugin.name],
        },
        swiftPmArtifactJunctionCapability: capabilities.swiftPmArtifact,
        packageLocalArtifactJunctionCapability:
            capabilities.packageLocalArtifact,
        consumedProducts: runtime.processPolicy.sourceFallbackActive
            ? await staging.workspaceStager.consumedProducts(outputDir)
            : const {},
        reconcileDependencies: !runtime.processPolicy.sourceFallbackActive
            ? null
            : (scratchPath, consumedProducts) async {
                final reconciled = await staging.workspaceStager
                    .reconcileCheckoutFallbacks(
                      outputDir: outputDir,
                      scratchPath: scratchPath,
                      consumedProducts: consumedProducts,
                    );
                if (reconciled.swiftModules) await stage();
                return SwiftPmManifestDependencies.sameConsumedProducts(
                      reconciled.consumedProducts,
                      consumedProducts,
                    )
                    ? null
                    : reconciled.consumedProducts;
              },
      );

      final result = await runtime.assembly.discoverAndRewriteDylibs(
        targetDebugDir,
        productName: pluginsProductName,
        packageIdentities: pluginIdentities,
      );
      await runtime.filesystem.writeStable(fingerprintFile.path, fingerprint);
      return result;
    },
  );
}
