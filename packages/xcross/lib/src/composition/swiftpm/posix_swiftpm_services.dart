import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/swiftpm/swiftpm_foundation.dart';
import 'package:xcross/src/host/shared/swiftpm/posix_build_execution.dart';
import 'package:xcross/src/host/shared/swiftpm/posix_dependency_preparation.dart';
import 'package:xcross/src/host/shared/swiftpm/posix_gate_platform.dart';
import 'package:xcross/src/shared/swiftpm/apple_host_tools.dart';
import 'package:xcross/src/shared/swiftpm/apple_tool_shims.dart';
import 'package:xcross/src/shared/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/swiftpm/checkout.dart';
import 'package:xcross/src/shared/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/swiftpm/librarian_resolver.dart';
import 'package:xcross/src/shared/swiftpm/package_builder.dart';
import 'package:xcross/src/shared/swiftpm/runtime.dart';
import 'package:xcross/src/shared/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/swiftpm/swiftpm_services.dart';
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';

/// SwiftPM services for POSIX hosts (macOS and Linux).
@internal
abstract class PosixSwiftPmServices<T extends PlatformHostInterface>
    implements SwiftPmServices<T> {
  const PosixSwiftPmServices({
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

  SwiftPmHostBuildServices<T> hostBuildServices(IosTarget<T> target);

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
      hostBuildServices: hostBuildServices(policy.target),
      librarianResolver: librarianResolver,
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
        PosixSwiftPmBuildExecution<T>(runner: runner),
        PosixSwiftPmDependencyPreparation<T>(
          runner: runner,
          processPolicy: foundation.processPolicy,
          networkRetry: foundation.networkRetry,
        ),
        checkout,
        checkoutAttributes,
        checkoutManifestNormalizer,
        foundation,
        PosixSwiftPmGatePlatform(fileSystem: artifactFileSystem),
      ),
    );
  }
}

/// Checks that the SwiftPM construction ports share one host and runner.
@internal
void requireSharedSwiftPmServices<T extends PlatformHostInterface>({
  required SwiftPmTargetPolicy<T> policy,
  required ProcessRunner<T> runner,
  required DarwinSdkRepository<T> repository,
  required DarwinToolchainResolver<T> toolchain,
  required SwiftPmCheckout<T> checkout,
  required SwiftPmCheckoutManifestNormalizer<T> checkoutManifestNormalizer,
  required SwiftPmArtifactFileSystem artifactFileSystem,
}) {
  final sharesHost =
      identical(policy.target.host, runner.host) &&
      identical(repository.host, runner.host);
  final sharesRunner =
      identical(toolchain.runner, runner) && identical(checkout.runner, runner);
  final sharesArtifactFileSystem =
      identical(checkout.fileSystem, artifactFileSystem) &&
      identical(checkoutManifestNormalizer.fileSystem, artifactFileSystem);
  final sharesCheckoutFilesystem = identical(
    checkout.repository.filesystem,
    checkoutManifestNormalizer.filesystem,
  );
  if (!sharesHost ||
      !sharesRunner ||
      !sharesArtifactFileSystem ||
      !sharesCheckoutFilesystem) {
    throw ArgumentError(
      'Flutter construction ports must share the selected host and configured services',
    );
  }
}

/// The Apple tool shim resolver for [target], as SwiftPM and Flutter
/// native assets use it.
@internal
AppleToolShimResolver<T> appleToolShimResolver<T extends PlatformHostInterface>(
  IosTarget<T> target, {
  required ProcessRunner<T> runner,
  required DarwinSdkRepository<T> repository,
  required DarwinToolchainResolver<T> toolchain,
  required AppleHostTools<T> hostTools,
  required AppleToolResolution resolution,
}) => AppleToolShimResolver(
  target,
  runner,
  repository,
  toolchain,
  hostTools: hostTools,
  executable: resolution.executable,
  launcher: resolution.launcher,
  xcrun: resolution.xcrun,
  openAppleMacrosServer: resolution.openAppleMacrosServer,
  declarative: resolution.declarative,
);
