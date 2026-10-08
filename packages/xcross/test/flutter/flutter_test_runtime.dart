import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/host/linux/linux_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/flutter/swiftpm_checkout.dart';
import 'package:xcross/src/composition/flutter/swiftpm_foundation.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/linux/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/host/linux/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';
import 'package:xcross/src/host/shared/flutter/posix_flutter_sdk_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_copy_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_filesystem.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_build_execution.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_attributes.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_link_creator.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_link_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_manifest_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_dependency_preparation.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_gate_platform.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/librarian_resolver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

import 'flutter_test_log.dart';

@internal
FlutterBuildRuntime<LinuxHost> testIPhoneRuntime({
  FlutterSdkHostPolicy<LinuxHost>? sdkHostPolicy,
  FlutterResolutionConfiguration resolution =
      const FlutterResolutionConfiguration(executable: '/xcross'),
}) {
  final host = LinuxHost(
    architecture: 'arm64',
    currentDirectory: Directory.current.path,
    temporaryDirectory: Directory.systemTemp.path,
  );
  return testFlutterRuntime(
    IPhoneFlutterTarget(IPhoneTarget(host)),
    resolution: resolution,
    sdkHostPolicy: sdkHostPolicy,
  );
}

@internal
FlutterBuildRuntime<LinuxHost> testSimulatorRuntime({
  FlutterResolutionConfiguration resolution =
      const FlutterResolutionConfiguration(executable: '/xcross'),
}) {
  final host = LinuxHost(
    architecture: 'arm64',
    currentDirectory: Directory.current.path,
    temporaryDirectory: Directory.systemTemp.path,
  );
  return testFlutterRuntime(
    SimulatorFlutterTarget(SimulatorTarget(host)),
    resolution: resolution,
  );
}

@internal
FlutterBuildRuntime<LinuxHost> testFlutterRuntime(
  FlutterTargetBuildPolicy<LinuxHost> policy, {
  FlutterSdkHostPolicy<LinuxHost>? sdkHostPolicy,
  FlutterResolutionConfiguration resolution =
      const FlutterResolutionConfiguration(executable: '/xcross'),
}) {
  final host = policy.target.host;
  final runner = ProcessRunner(
    host,
    log: testFlutterLog(),
    stdinStream: const Stream<List<int>>.empty(),
    stdoutSink: stdout,
    stderrSink: stderr,
  );
  final repository = DarwinSdkRepository(host, log: runner.log);
  final toolchain = DarwinToolchainResolver(
    runner,
    LinuxDarwinToolchainLocations(host),
  );
  final hostTools = LinuxNativeHostTools(host, runner);
  final renderer = PosixAppleToolShimRenderer(host);
  final tools = AppleToolShimResolver(
    policy.target,
    runner,
    repository,
    toolchain,
    hostTools: hostTools,
    executable: resolution.executable,
  );
  final artifactFileSystem = PosixSwiftPmArtifactFileSystem(host);
  const hostPolicy = LinuxSwiftPmHostPolicy();
  const sdkIdentity = TestSwiftPmSdkIdentity();
  const transport = HttpSwiftPmArchiveTransport(createClient: HttpClient.new);
  final copyPolicy = PosixSwiftPmArtifactCopyPolicy(artifactFileSystem);
  final publicationCoordinator = SwiftPmPublicationCoordinator(
    locks: FileSwiftPmPublicationLockProvider(artifactFileSystem),
    pathKey: host.paths.pathKey,
  );
  final parts = SwiftPmCheckoutAssemblyParts.prepare(
    runner: runner,
    fileSystem: artifactFileSystem,
  );
  const attributes = PosixSwiftPmCheckoutAttributes();
  final checkout = assembleSwiftPmCheckout(
    parts: parts,
    gitPolicy: const PosixSwiftPmCheckoutGitPolicy(),
    fallback: PosixSwiftPmCheckoutFallback(
      fileSystem: artifactFileSystem,
      filesystem: parts.filesystem,
      graph: parts.graph,
    ),
    attributes: attributes,
    linkCreator: PosixSwiftPmCheckoutLinkCreator(artifactFileSystem),
  );
  final normalizer = SwiftPmCheckoutManifestNormalizer(
    fileSystem: artifactFileSystem,
    filesystem: parts.filesystem,
    attributes: attributes,
    policy: PosixSwiftPmVendoredManifestPolicy(
      sourceNormalizer: parts.sourceNormalizer,
      sourceFallback: parts.sourceFallback,
    ),
  );
  final librarianResolver = SwiftPmLibrarianResolver(
    runner: runner,
    filesystem: parts.filesystem,
    lookup: DarwinSwiftPmLlvmToolLookup(toolchain),
  );
  final hostBuildServices = LinuxSwiftPmHostBuildServices(
    target: policy.target,
    filesystem: parts.filesystem,
    sdkIdentity: sdkIdentity,
  );
  final foundation = prepareSwiftPmFoundation(
    hostBuildServices: hostBuildServices,
    librarianResolver: librarianResolver,
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
    checkoutAttributes: attributes,
    filesystem: parts.filesystem,
  );
  final plugins = GeneratedPluginsPackage(
    policy,
    runner: runner,
    sdkRepository: repository,
    toolchain: toolchain,
    tools: tools,
    hostPolicy: hostPolicy,
    artifactFileSystem: artifactFileSystem,
    transport: transport,
    copyPolicy: copyPolicy,
    publicationCoordinator: publicationCoordinator,
    sdkIdentity: sdkIdentity,
    foundation: foundation,
    gatePlatform: PosixSwiftPmGatePlatform(fileSystem: artifactFileSystem),
    checkout: checkout,
    checkoutAttributes: attributes,
    checkoutManifestNormalizer: normalizer,
    buildExecution: PosixSwiftPmBuildExecution(runner: runner),
    dependencyPreparation: PosixSwiftPmDependencyPreparation<LinuxHost>(
      runner: runner,
      processPolicy: foundation.processPolicy,
      networkRetry: foundation.networkRetry,
    ),
  );
  return FlutterBuildRuntime(
    policy: policy,
    runner: runner,
    sdkRepository: repository,
    toolchain: toolchain,
    hostTools: hostTools,
    toolShimRenderer: renderer,
    sdkHostPolicy: sdkHostPolicy ?? PosixFlutterSdkPolicy(),
    plugins: plugins,
    downloader: Downloader(createClient: HttpClient.new, log: runner.log),
    resolution: resolution,
  );
}

@internal
final class TestSwiftPmSdkIdentity implements SwiftPmSdkIdentity {
  const TestSwiftPmSdkIdentity();
  @override
  String get platformIdentity => 'test-linux-arm64';
  @override
  Future<Map<String, Object>> hostToolchainIdentity() async => const {};
  @override
  Future<Map<String, Object>> sdkBuildIdentity(String sdkRoot) async =>
      const {};
  @override
  Future<String?> hostToolchainMismatch(String sdkRoot) async => null;
  @override
  String mismatchGuidance(String? detail) => detail ?? '';
  @override
  Future<Map<String, Object>> swiftPmBuildToolchainIdentity({
    required String cCompilerPath,
    required String cxxCompilerPath,
    required String linkerPath,
    required String librarianPath,
  }) async => const {};
}
