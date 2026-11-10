import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/swiftpm/posix_swiftpm_services.dart';
import 'package:xcross/src/composition/swiftpm/swiftpm_foundation.dart';
import 'package:xcross/src/host/windows/swiftpm/build_execution.dart';
import 'package:xcross/src/host/windows/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/host/windows/swiftpm/gate_platform.dart';
import 'package:xcross/src/host/windows/swiftpm/host_build_services.dart';
import 'package:xcross/src/host/windows/swiftpm/windows_swift_plan_repair.dart';
import 'package:xcross/src/shared/swiftpm/apple_host_tools.dart';
import 'package:xcross/src/shared/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/swiftpm/checkout.dart';
import 'package:xcross/src/shared/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/swiftpm/foundation.dart';
import 'package:xcross/src/shared/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/swiftpm/librarian_resolver.dart';
import 'package:xcross/src/shared/swiftpm/package_builder.dart';
import 'package:xcross/src/shared/swiftpm/runtime.dart';
import 'package:xcross/src/shared/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/swiftpm/swiftpm_binary_fixture.dart';
import 'package:xcross/src/shared/swiftpm/swiftpm_services.dart';
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';

/// SwiftPM services for Windows hosts.
@internal
final class WindowsSwiftPmServices<T extends WindowsHostInterface>
    implements SwiftPmServices<T> {
  const WindowsSwiftPmServices({
    required this.checkout,
    required this.checkoutAttributes,
    required this.checkoutManifestNormalizer,
    required this.runner,
    required this.repository,
    required this.toolchain,
    required this.hostTools,
    required this.hostPolicy,
    required this.artifactFileSystem,
    required this.sdkIdentity,
    required this.resolution,
    required this.publicationCoordinator,
    required this.transport,
    required this.copyPolicy,
  });

  final SwiftPmPublicationCoordinator publicationCoordinator;
  final SwiftPmArchiveTransport transport;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  final SwiftPmCheckout<T> checkout;
  final SwiftPmCheckoutAttributes checkoutAttributes;
  final SwiftPmCheckoutManifestNormalizer<T> checkoutManifestNormalizer;
  @override
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> repository;
  final DarwinToolchainResolver<T> toolchain;
  final AppleHostTools<T> hostTools;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmSdkIdentity sdkIdentity;
  final AppleToolResolution resolution;

  @override
  SwiftPmPackageBuilder<T> builder(SwiftPmTargetPolicy<T> policy) {
    requireSharedSwiftPmServices(
      policy: policy,
      runner: runner,
      repository: repository,
      toolchain: toolchain,
      checkout: checkout,
      checkoutManifestNormalizer: checkoutManifestNormalizer,
      artifactFileSystem: artifactFileSystem,
    );
    final tools = appleToolShimResolver(
      policy.target,
      runner: runner,
      repository: repository,
      toolchain: toolchain,
      hostTools: hostTools,
      resolution: resolution,
    );
    final librarianResolver = SwiftPmLibrarianResolver<T>(
      runner: runner,
      filesystem: checkoutManifestNormalizer.filesystem,
      lookup: DarwinSwiftPmLlvmToolLookup(toolchain),
    );
    final buildServices = WindowsSwiftPmHostBuildServices<T>(
      target: policy.target,
      filesystem: checkoutManifestNormalizer.filesystem,
      sdkIdentity: sdkIdentity,
      runner: runner,
      sdkRepository: repository,
      toolchainResolver: toolchain,
      librarianResolver: librarianResolver,
    );
    final foundation = prepareSwiftPmFoundation<T>(
      policy: policy,
      runner: runner,
      sdkRepository: repository,
      toolchainResolver: toolchain,
      tools: tools,
      hostPolicy: hostPolicy,
      artifactFileSystem: artifactFileSystem,
      sdkIdentity: sdkIdentity,
      publicationCoordinator: publicationCoordinator,
      transport: transport,
      copyPolicy: copyPolicy,
      filesystem: checkoutManifestNormalizer.filesystem,
      checkoutAttributes: checkoutAttributes,
      hostBuildServices: buildServices,
      librarianResolver: librarianResolver,
    );
    final buildExecution = WindowsSwiftPmBuildExecution<T>(
      runner: runner,
      repair: WindowsSwiftPlanRepair(runner),
      consumerRepair: foundation.consumerRepair,
    );
    final dependencyPreparation = WindowsSwiftPmDependencyPreparation<T>(
      runner: runner,
      checkout: checkout,
      metadata: foundation.packageMetadata,
      processPolicy: foundation.processPolicy,
      networkRetry: foundation.networkRetry,
      binaryRecovery: foundation.binaryRecovery,
      extractedArtifacts: foundation.extractedArtifacts,
    );
    return SwiftPmPackageBuilder<T>(
      SwiftPmRuntime(
        policy,
        runner,
        repository,
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
        _gatePlatform(policy, foundation),
      ),
    );
  }

  WindowsSwiftPmGatePlatform<T> _gatePlatform(
    SwiftPmTargetPolicy<T> policy,
    SwiftPmFoundation<T> foundation,
  ) {
    final fixtureGenerator = SwiftPmBinaryFixtureGenerator(
      fileSystem: runner.host.fileSystem,
      paths: runner.host.paths.context,
    );
    return WindowsSwiftPmGatePlatform<T>(
      fixtureGenerator: fixtureGenerator,
      execution: foundation.gateExecution,
      fileSystem: artifactFileSystem,
      sdkRepository: repository,
      toolchain: foundation.toolchain,
      processPolicy: foundation.processPolicy,
      buildPlan: foundation.buildPlan,
      targetPolicy: policy,
      log: runner.log,
    );
  }
}
