import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/linux/flutter/swiftpm/swiftpm_host_policy.dart';

import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';
import 'package:xcross/src/host/shared/flutter/posix_flutter_sdk_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_copy_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_filesystem.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_build_execution.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

import 'flutter_test_log.dart';

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
  final plugins = GeneratedPluginsPackage(
    policy,
    runner: runner,
    sdkRepository: repository,
    toolchain: toolchain,
    tools: tools,
    hostPolicy: const LinuxSwiftPmHostPolicy(),
    artifactFileSystem: artifactFileSystem,
    transport: const HttpSwiftPmArchiveTransport(createClient: HttpClient.new),
    copyPolicy: PosixSwiftPmArtifactCopyPolicy(artifactFileSystem),
    publicationCoordinator: SwiftPmPublicationCoordinator(
      locks: FileSwiftPmPublicationLockProvider(artifactFileSystem),
      pathKey: host.paths.pathKey,
    ),
    sdkIdentity: const TestSwiftPmSdkIdentity(),
    buildExecution: PosixSwiftPmBuildExecution(runner: runner),
    dependencyPreparation: const PosixSwiftPmDependencyPreparation<LinuxHost>(),
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
