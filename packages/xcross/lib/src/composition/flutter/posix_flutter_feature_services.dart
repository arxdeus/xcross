import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/flutter/swiftpm_foundation.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_build_execution.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_dependency_preparation.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_gate_platform.dart';
import 'package:xcross/src/shared/flutter/build/flutter_aot_snapshotter.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/librarian_resolver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/runtime/flutter_feature_services.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
abstract class PosixFlutterFeatureServices<T extends PlatformHostInterface>
    implements FlutterFeatureServices<T> {
  const PosixFlutterFeatureServices({
    required this.checkout,
    required this.checkoutAttributes,
    required this.checkoutManifestNormalizer,
    required this.runner,
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
    this.aotCompilers,
  });

  final IosAotCompilerLocator? aotCompilers;

  final SwiftPmPublicationCoordinator publicationCoordinator;
  final SwiftPmArchiveTransport transport;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  final SwiftPmCheckout<T> checkout;
  final SwiftPmCheckoutAttributes checkoutAttributes;
  final SwiftPmCheckoutManifestNormalizer<T> checkoutManifestNormalizer;
  final Downloader downloader;
  @override
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

  SwiftPmHostBuildServices<T> hostBuildServices(IosTarget<T> target);

  @override
  FlutterBuildRuntime<T> build(FlutterTargetBuildPolicy<T> policy) {
    _requireSharedHostServices(policy);
    final tools = _toolShimResolver(policy);
    final librarianResolver = _librarianResolver();
    final buildServices = hostBuildServices(policy.target);
    final foundation = prepareSwiftPmFoundation<T>(
      policy: policy,
      runner: runner,
      sdkRepository: repository,
      toolchainResolver: toolchain,
      tools: tools,
      hostPolicy: swiftPmPolicy,
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
    final buildExecution = PosixSwiftPmBuildExecution<T>(runner: runner);
    final dependencyPreparation = PosixSwiftPmDependencyPreparation<T>(
      runner: runner,
      processPolicy: foundation.processPolicy,
      networkRetry: foundation.networkRetry,
    );
    final gatePlatform = PosixSwiftPmGatePlatform(
      fileSystem: artifactFileSystem,
    );
    final plugins = GeneratedPluginsPackage(
      policy,
      foundation: foundation,
      gatePlatform: gatePlatform,
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
      aotCompilers: aotCompilers,
    );
  }

  void _requireSharedHostServices(FlutterTargetBuildPolicy<T> policy) {
    final sharesHost =
        identical(policy.target.host, runner.host) &&
        identical(repository.host, runner.host);
    final sharesRunner =
        identical(toolchain.runner, runner) &&
        identical(checkout.runner, runner);
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

  AppleToolShimResolver<T> _toolShimResolver(
    FlutterTargetBuildPolicy<T> policy,
  ) => AppleToolShimResolver(
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

  SwiftPmLibrarianResolver<T> _librarianResolver() =>
      SwiftPmLibrarianResolver<T>(
        runner: runner,
        filesystem: checkoutManifestNormalizer.filesystem,
        lookup: DarwinSwiftPmLlvmToolLookup(toolchain),
      );
}
