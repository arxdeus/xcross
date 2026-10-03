import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

final class FlutterFeatureServices<T extends PlatformHostInterface> {
  const FlutterFeatureServices({
    required this.checkout,
    required this.checkoutAttributes,
    required this.checkoutManifestNormalizer,
    required this.runner,
    required this.buildExecution,
    required this.dependencyPreparation,
    required this.repository,
    required this.toolchain,
    required this.hostTools,
    required this.renderer,
    required this.sdkPolicy,
    required this.swiftPmPolicy,
    required this.artifactFileSystem,
    required this.sdkIdentity,
    required this.resolution,
    required this.downloader,
    required this.publicationCoordinator,
    required this.transport,
    required this.copyPolicy,
  });

  final SwiftPmPublicationCoordinator publicationCoordinator;
  final SwiftPmArchiveTransport transport;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  final SwiftPmBuildExecution<T> buildExecution;
  final SwiftPmDependencyPreparation<T> dependencyPreparation;
  final SwiftPmCheckout<T> checkout;
  final SwiftPmCheckoutAttributes checkoutAttributes;
  final SwiftPmCheckoutManifestNormalizer<T> checkoutManifestNormalizer;
  final Downloader downloader;
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> repository;
  final DarwinToolchainResolver<T> toolchain;
  final NativeHostTools<T> hostTools;
  final AppleToolShimRenderer<T> renderer;
  final FlutterSdkHostPolicy<T> sdkPolicy;
  final SwiftPmHostPolicy swiftPmPolicy;
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmSdkIdentity sdkIdentity;
  final FlutterResolutionConfiguration resolution;

  FlutterBuildRuntime<T> build(FlutterTargetBuildPolicy<T> policy) {
    final tools = AppleToolShimResolver(
      policy.target,
      runner,
      repository,
      toolchain,
      hostTools: hostTools,
      executable: resolution.executable,
      launcher: resolution.launcher,
      xcrun: resolution.xcrun,
      declarative: resolution.declarative,
    );
    final plugins = GeneratedPluginsPackage(
      policy,
      checkout: checkout,
      checkoutAttributes: checkoutAttributes,
      checkoutManifestNormalizer: checkoutManifestNormalizer,
      buildExecution: buildExecution,
      dependencyPreparation: dependencyPreparation,
      runner: runner,
      sdkRepository: repository,
      toolchain: toolchain,
      tools: tools,
      hostPolicy: swiftPmPolicy,
      artifactFileSystem: artifactFileSystem,
      publicationCoordinator: publicationCoordinator,
      transport: transport,
      copyPolicy: copyPolicy,
      sdkIdentity: sdkIdentity,
    );
    return FlutterBuildRuntime(
      policy: policy,
      runner: runner,
      sdkRepository: repository,
      toolchain: toolchain,
      hostTools: hostTools,
      toolShimRenderer: renderer,
      sdkHostPolicy: sdkPolicy,
      downloader: downloader,
      plugins: plugins,
      resolution: resolution,
    );
  }
}
