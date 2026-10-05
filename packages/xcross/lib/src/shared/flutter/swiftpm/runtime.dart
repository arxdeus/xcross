import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:open_apple_macros/shared/open_apple_macros_server.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/host_symlink_capability.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_capabilities.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/assembly.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_layout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_driver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_evaluator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_vendor.dart';
import 'package:xcross/src/shared/flutter/swiftpm/discovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/extracted_artifact_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/foundation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_consumer_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/librarian_resolver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/module_files.dart';
import 'package:xcross/src/shared/flutter/swiftpm/network_retry.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plan_reader.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plugin_overlay.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';
import 'package:xcross/src/shared/flutter/swiftpm/workspace_stager.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
final class SwiftPmRuntime<T extends PlatformHostInterface> {
  SwiftPmRuntime(
    this.targetPolicy,
    this.runner,
    this.sdkRepository,
    this.toolchainResolver,
    this.tools,
    this.hostPolicy,
    this.artifactFileSystem,
    this.sdkIdentity,
    this.publicationCoordinator,
    this.transport,
    this.copyPolicy,
    this.buildExecution,
    this.dependencyPreparation,
    this.checkout,
    this.checkoutAttributes,
    this.checkoutManifestNormalizer,
    this.foundation,
    this.gatePlatform,
  ) {
    if (!identical(foundation.targetPolicy, targetPolicy) ||
        !identical(foundation.runner, runner) ||
        !identical(foundation.sdkRepository, sdkRepository) ||
        !identical(foundation.toolchainResolver, toolchainResolver) ||
        !identical(foundation.tools, tools) ||
        !identical(foundation.hostPolicy, hostPolicy) ||
        !identical(foundation.artifactFileSystem, artifactFileSystem) ||
        !identical(foundation.sdkIdentity, sdkIdentity) ||
        !identical(foundation.publicationCoordinator, publicationCoordinator) ||
        !identical(foundation.transport, transport) ||
        !identical(foundation.copyPolicy, copyPolicy) ||
        !identical(foundation.checkoutAttributes, checkoutAttributes) ||
        !identical(checkout.runner, runner) ||
        !identical(checkout.fileSystem, artifactFileSystem) ||
        !identical(checkoutManifestNormalizer.fileSystem, artifactFileSystem) ||
        !identical(
          checkoutManifestNormalizer.filesystem,
          foundation.filesystem,
        )) {
      throw ArgumentError(
        'SwiftPM composition ports must share the configured foundation',
      );
    }
    if (!identical(gatePlatform.fileSystem, artifactFileSystem) ||
        !gatePlatform.matchesTarget(targetPolicy)) {
      throw ArgumentError(
        'SwiftPM gate must share the configured filesystem and target policy',
      );
    }
    hostBuildServices = foundation.hostBuildServices;
    librarianResolver = foundation.librarianResolver;
    processPolicy = foundation.processPolicy;
    sourceRepair = foundation.sourceRepair;
    toolchain = foundation.toolchain;
    macroServer = foundation.macroServer;
    planReader = foundation.planReader;
    buildPlan = foundation.buildPlan;
    consumerRepair = foundation.consumerRepair;
    networkRetry = foundation.networkRetry;
    binaryLayout = foundation.binaryLayout;
    binaryProvenance = foundation.binaryProvenance;
    binaryPreparation = foundation.binaryPreparation;
    binaryRecovery = foundation.binaryRecovery;
    extractedArtifacts = foundation.extractedArtifacts;
    packageMetadata = foundation.packageMetadata;
    filesystem = foundation.filesystem;
    symlinks = HostSymlinkCapability(host);
    sourceNormalizer = SwiftPmHostSourceNormalizer(
      fileSystem: artifactFileSystem,
    );
    moduleFiles = SwiftPmModuleFiles(fileSystem: artifactFileSystem);
    manifest = SwiftPmManifest<T>(targetPolicy: targetPolicy);
    sourceFallback = SwiftPmSourceFallback<T>(
      filesystem: filesystem,
      moduleFiles: moduleFiles,
    );
    dependencyEvaluator = SwiftPmDependencyEvaluator<T>(
      artifactFileSystem: artifactFileSystem,
      dependencyPreparation: dependencyPreparation,
      hostPolicy: hostPolicy,
      networkRetry: networkRetry,
      sourceRepair: sourceRepair,
    );
    dependencyVendor = SwiftPmDependencyVendor<T>(
      checkout: checkout,
      checkoutManifestNormalizer: checkoutManifestNormalizer,
      dependencyPreparation: dependencyPreparation,
      runner: runner,
      dependencyEvaluator: dependencyEvaluator,
      binaryProvenance: binaryProvenance,
      processPolicy: processPolicy,
    );
    pluginOverlay = SwiftPmPluginOverlay<T>(
      dependencyVendor: dependencyVendor,
      manifestPolicy: checkoutManifestNormalizer.policy,
      filesystem: filesystem,
      sourceNormalizer: sourceNormalizer,
      binaryPreparation: binaryPreparation,
    );
    workspaceStager = SwiftPmWorkspaceStager<T>(
      hostBuildServices: hostBuildServices,
      artifactFileSystem: artifactFileSystem,
      checkout: checkout,
      dependencyPreparation: dependencyPreparation,
      filesystem: filesystem,
      hostPolicy: hostPolicy,
      manifest: manifest,
      pluginOverlay: pluginOverlay,
      runner: runner,
      sourceNormalizer: sourceNormalizer,
      dependencyEvaluator: dependencyEvaluator,
    );
    buildDriver = SwiftPmBuildDriver<T>(
      hostBuildServices: hostBuildServices,
      buildPlan: buildPlan,
      hostPolicy: hostPolicy,
      consumerRepair: consumerRepair,
      planReader: planReader,
      processPolicy: processPolicy,
      runner: runner,
      sdkIdentity: sdkIdentity,
      sdkRepository: sdkRepository,
      sourceRepair: sourceRepair,
      target: target,
      targetPolicy: targetPolicy,
      toolchain: toolchain,
      toolchainResolver: toolchainResolver,
      tools: tools,
      buildExecution: buildExecution,
      dependencyPreparation: dependencyPreparation,
      checkout: checkout,
    );
    discovery = SwiftPmDiscovery<T>(
      hostPolicy: hostPolicy,
      sdkIdentity: sdkIdentity,
      sdkRepository: sdkRepository,
      toolchain: toolchain,
    );
    assembly = SwiftPmAssembly<T>(
      hostBuildServices: hostBuildServices,
      fileSystem: artifactFileSystem,
    );
    gateExecution = foundation.gateExecution;
    artifactCapabilities = SwiftPmArtifactCapabilities<T>(
      paths: host.paths,
      fileSystem: artifactFileSystem,
      repository: sdkRepository,
      platform: gatePlatform,
      identities: SwiftPmArtifactIdentityResolver<T>(
        repository: sdkRepository,
        sdkIdentity: sdkIdentity,
        toolchain: toolchain,
      ),
    );
  }

  late final SwiftPmPlanReader planReader;
  late final SwiftPmInteropConsumerRepair<T> consumerRepair;
  final SwiftPmFoundation<T> foundation;
  final SwiftPmGatePlatform gatePlatform;
  late final SwiftPmHostBuildServices<T> hostBuildServices;
  late final SwiftPmLibrarianResolver<T> librarianResolver;
  IosTarget<T> get target => targetPolicy.target;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  T get host => target.host;

  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> sdkRepository;
  final DarwinToolchainResolver<T> toolchainResolver;
  final AppleToolShimResolver<T> tools;
  late final HostSymlinkCapability symlinks;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmSdkIdentity sdkIdentity;
  final SwiftPmPublicationCoordinator publicationCoordinator;
  final SwiftPmArchiveTransport transport;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  final SwiftPmBuildExecution<T> buildExecution;
  final SwiftPmDependencyPreparation<T> dependencyPreparation;
  late final SwiftPmGateExecution<T> gateExecution;
  late final SwiftPmArtifactCapabilities<T> artifactCapabilities;
  late final SwiftPmPluginOverlay<T> pluginOverlay;
  late final SwiftPmWorkspaceStager<T> workspaceStager;
  late final SwiftPmBuildDriver<T> buildDriver;

  late final SwiftPmDiscovery<T> discovery;
  late final SwiftPmAssembly<T> assembly;
  final SwiftPmCheckout<T> checkout;
  final SwiftPmCheckoutAttributes checkoutAttributes;
  final SwiftPmCheckoutManifestNormalizer<T> checkoutManifestNormalizer;
  late final SwiftPmHostSourceNormalizer sourceNormalizer;
  late final SwiftPmModuleFiles moduleFiles;
  late final SwiftPmPackageMetadata packageMetadata;
  late final SwiftPmManifest<T> manifest;
  late final SwiftPmSourceRepair<T> sourceRepair;
  late final SwiftPmSourceFallback<T> sourceFallback;
  late final SwiftPmDependencyVendor<T> dependencyVendor;
  late final SwiftPmFilesystem<T> filesystem;
  late final SwiftPmToolchain<T> toolchain;
  late final SwiftPmNetworkRetry<T> networkRetry;
  late final SwiftPmBinaryPreparation<T> binaryPreparation;
  late final SwiftPmExtractedArtifactRecovery<T> extractedArtifacts;
  late final SwiftPmBinaryProvenance<T> binaryProvenance;
  late final SwiftPmBinaryLayout<T> binaryLayout;
  late final SwiftPmDependencyEvaluator<T> dependencyEvaluator;
  late final SwiftPmBinaryRecovery<T> binaryRecovery;
  late final OpenAppleMacrosServer<T> macroServer;
  late final SwiftPmBuildPlan<T> buildPlan;
  late final SwiftPmProcessPolicy<T> processPolicy;
}
