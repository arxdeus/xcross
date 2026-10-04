import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/composition/flutter/swiftpm_checkout.dart';
import 'package:xcross/src/composition/flutter/swiftpm_foundation.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/windows_swift_plan_repair.dart';
import 'package:xcross/src/host/linux/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/host/linux/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
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
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_link_policy.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_manifest_policy.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/pinned_dependency_resolver.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_git_repository.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_build_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/librarian_resolver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

SwiftPmRuntime<MacOSHost> testSwiftPmRuntime({
  SwiftPmHostPolicy? hostPolicy,
  FlutterTargetBuildPolicy<MacOSHost> Function(MacOSHost)? targetPolicy,
  Map<String, String>? environment,
  SwiftPmSdkIdentity? sdkIdentity,
}) {
  final host = MacOSHost(
    environment: environment ?? Platform.environment,
    currentDirectory: Directory.current.path,
    temporaryDirectory: Directory.systemTemp.path,
  );
  final runner = ProcessRunner(
    host,
    log: testSwiftPmLog(),
    stdinStream: const Stream<List<int>>.empty(),
    stdoutSink: stdout,
    stderrSink: stderr,
  );
  final repository = DarwinSdkRepository(
    host,
    log: testSwiftPmLog(),
    installBundle: p.join(Directory.systemTemp.path, 'xcross-unit-no-sdk-$pid'),
  );
  final toolchain = DarwinToolchainResolver(
    runner,
    MacOSDarwinToolchainLocations(host),
  );
  final policy =
      targetPolicy?.call(host) ?? IPhoneFlutterTarget(IPhoneTarget(host));
  final tools = AppleToolShimResolver(
    policy.target,
    runner,
    repository,
    toolchain,
    hostTools: MacOSNativeHostTools(host, runner),
    executable: Platform.resolvedExecutable,
  );
  final artifactFileSystem = PosixSwiftPmArtifactFileSystem(host);
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
    environment: runner.effectiveEnvironment,
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

  final selectedHostPolicy = hostPolicy ?? const LinuxSwiftPmHostPolicy();
  final selectedIdentity = sdkIdentity ?? const TestSwiftPmSdkIdentity();
  final coordinator = SwiftPmPublicationCoordinator(
    locks: FileSwiftPmPublicationLockProvider(artifactFileSystem),
    pathKey: host.paths.pathKey,
  );
  const transport = HttpSwiftPmArchiveTransport(createClient: HttpClient.new);
  final copyPolicy = PosixSwiftPmArtifactCopyPolicy(artifactFileSystem);
  final librarianResolver = SwiftPmLibrarianResolver(
    runner: runner,
    filesystem: parts.filesystem,
    lookup: DarwinSwiftPmLlvmToolLookup(toolchain),
  );
  final hostBuildServices = LinuxSwiftPmHostBuildServices(
    target: policy.target,
    filesystem: parts.filesystem,
    sdkIdentity: selectedIdentity,
  );
  final foundation = prepareSwiftPmFoundation(
    hostBuildServices: hostBuildServices,
    librarianResolver: librarianResolver,
    policy: policy,
    runner: runner,
    sdkRepository: repository,
    toolchainResolver: toolchain,
    tools: tools,
    hostPolicy: selectedHostPolicy,
    artifactFileSystem: artifactFileSystem,
    sdkIdentity: selectedIdentity,
    publicationCoordinator: coordinator,
    transport: transport,
    copyPolicy: copyPolicy,
    filesystem: parts.filesystem,
    checkoutAttributes: attributes,
  );
  return SwiftPmRuntime(
    policy,
    runner,
    repository,
    toolchain,
    tools,
    selectedHostPolicy,
    artifactFileSystem,
    selectedIdentity,
    coordinator,
    transport,
    copyPolicy,
    PosixSwiftPmBuildExecution(
      runner: runner,
      sourceRepair: foundation.sourceRepair,
    ),
    const PosixSwiftPmDependencyPreparation(),
    checkout,
    attributes,
    normalizer,
    foundation,
    PosixSwiftPmGatePlatform(fileSystem: artifactFileSystem),
  );
}

SwiftPmRuntime<WindowsHost> testWindowsSwiftPmRuntime({
  String? currentDirectory,
  Map<String, String>? environment,
  SwiftPmSdkIdentity? sdkIdentity,
  FlutterTargetBuildPolicy<WindowsHost> Function(WindowsHost)? targetPolicy,
}) {
  final native = MacOSHost(
    environment: Platform.environment,
    currentDirectory: currentDirectory ?? Directory.current.path,
    temporaryDirectory: Directory.systemTemp.path,
  );
  final host = WindowsHost(
    environment: environment ?? Platform.environment,
    architecture: 'x64',
    paths: WindowsTestPaths(native.paths, environment ?? Platform.environment),
    fileSystem: native.fileSystem,
    processes: native.processes,
  );
  final runner = ProcessRunner(
    host,
    log: testSwiftPmLog(),
    stdinStream: const Stream<List<int>>.empty(),
    stdoutSink: stdout,
    stderrSink: stderr,
  );
  final repository = DarwinSdkRepository(
    host,
    log: testSwiftPmLog(),
    installBundle: p.join(Directory.systemTemp.path, 'xcross-unit-no-sdk-$pid'),
  );
  final toolchain = DarwinToolchainResolver(
    runner,
    WindowsDarwinToolchainLocations(host),
  );
  final policy =
      targetPolicy?.call(host) ?? IPhoneFlutterTarget(IPhoneTarget(host));
  final tools = AppleToolShimResolver(
    policy.target,
    runner,
    repository,
    toolchain,
    hostTools: WindowsNativeHostTools(host, runner),
    executable: Platform.resolvedExecutable,
  );
  final artifactFileSystem = PosixSwiftPmArtifactFileSystem(host);
  final parts = SwiftPmCheckoutAssemblyParts.prepare(
    runner: runner,
    fileSystem: artifactFileSystem,
  );
  const attributes = PosixSwiftPmCheckoutAttributes();
  final checkout = assembleSwiftPmCheckout(
    parts: parts,
    gitPolicy: WindowsSwiftPmCheckoutGitPolicy(symlinks: parts.symlinks),
    fallback: WindowsSwiftPmCheckoutFallback(
      runner: runner,
      fileSystem: artifactFileSystem,
      filesystem: parts.filesystem,
      stamps: parts.stamps,
      graph: parts.graph,
    ),
    attributes: attributes,
    linkCreator: PosixSwiftPmCheckoutLinkCreator(artifactFileSystem),
    environment: runner.effectiveEnvironment,
  );
  final normalizer = SwiftPmCheckoutManifestNormalizer(
    fileSystem: artifactFileSystem,
    filesystem: parts.filesystem,
    attributes: attributes,
    policy: WindowsSwiftPmVendoredManifestPolicy(
      sourceNormalizer: parts.sourceNormalizer,
      sourceFallback: parts.sourceFallback,
    ),
  );

  final selectedHostPolicy = WindowsSwiftPmHostPolicy(runner);
  final selectedIdentity = sdkIdentity ?? const TestSwiftPmSdkIdentity();
  final coordinator = SwiftPmPublicationCoordinator(
    locks: FileSwiftPmPublicationLockProvider(artifactFileSystem),
    pathKey: host.paths.pathKey,
  );
  const transport = HttpSwiftPmArchiveTransport(createClient: HttpClient.new);
  final copyPolicy = PosixSwiftPmArtifactCopyPolicy(artifactFileSystem);
  final librarianResolver = SwiftPmLibrarianResolver(
    runner: runner,
    filesystem: parts.filesystem,
    lookup: DarwinSwiftPmLlvmToolLookup(toolchain),
  );
  final hostBuildServices = WindowsSwiftPmHostBuildServices(
    target: policy.target,
    filesystem: parts.filesystem,
    sdkIdentity: selectedIdentity,
    runner: runner,
    sdkRepository: repository,
    toolchainResolver: toolchain,
    librarianResolver: librarianResolver,
  );
  final foundation = prepareSwiftPmFoundation(
    hostBuildServices: hostBuildServices,
    librarianResolver: librarianResolver,
    policy: policy,
    runner: runner,
    sdkRepository: repository,
    toolchainResolver: toolchain,
    tools: tools,
    hostPolicy: selectedHostPolicy,
    artifactFileSystem: artifactFileSystem,
    sdkIdentity: selectedIdentity,
    publicationCoordinator: coordinator,
    transport: transport,
    copyPolicy: copyPolicy,
    filesystem: parts.filesystem,
    checkoutAttributes: attributes,
  );
  return SwiftPmRuntime(
    policy,
    runner,
    repository,
    toolchain,
    tools,
    selectedHostPolicy,
    artifactFileSystem,
    selectedIdentity,
    coordinator,
    transport,
    copyPolicy,
    WindowsSwiftPmBuildExecution(
      runner: runner,
      repair: WindowsSwiftPlanRepair(runner),
      sourceRepair: foundation.sourceRepair,
      consumerRepair: foundation.consumerRepair,
    ),
    WindowsSwiftPmDependencyPreparation(
      runner: runner,
      checkout: checkout,
      fileSystem: artifactFileSystem,
      manifestNormalizer: normalizer,
      metadata: foundation.packageMetadata,
      processPolicy: foundation.processPolicy,
      networkRetry: foundation.networkRetry,
      binaryPreparation: foundation.binaryPreparation,
      binaryRecovery: foundation.binaryRecovery,
      binaryProvenance: foundation.binaryProvenance,
      extractedArtifacts: foundation.extractedArtifacts,
      pinnedResolver: WindowsSwiftPmPinnedDependencyResolver(
        runner: runner,
        fileSystem: artifactFileSystem,
        filesystem: parts.filesystem,
        repository: checkout.repository,
        manifestNormalizer: normalizer,
      ),
    ),
    checkout,
    attributes,
    normalizer,
    foundation,
    WindowsSwiftPmGatePlatform(
      execution: foundation.gateExecution,
      fileSystem: artifactFileSystem,
      sdkRepository: repository,
      toolchain: foundation.toolchain,
      processPolicy: foundation.processPolicy,
      buildPlan: foundation.buildPlan,
      targetPolicy: policy,
      log: runner.log,
    ),
  );
}

final class WindowsTestPaths implements HostPathsInterface {
  WindowsTestPaths(this.native, Map<String, String> environment)
    : windows = WindowsPaths(environment: environment, context: native.context);
  final WindowsPaths windows;
  final HostPathsInterface native;
  @override
  p.Context get context => native.context;
  @override
  String get configRoot => native.configRoot;
  @override
  String get cacheRoot => windows.cacheRoot;
  @override
  String get temporaryRoot => native.temporaryRoot;
  @override
  String ioPath(String path) => native.ioPath(path);
  @override
  String pathKey(String path) => native.pathKey(path).toLowerCase();
  @override
  String executableName(String name, {String extension = '.exe'}) =>
      name.endsWith(extension) ? name : '$name$extension';
}

SwiftPmRuntime<MacOSHost> testSimulatorSwiftPmRuntime() => testSwiftPmRuntime(
  targetPolicy: (host) => SimulatorFlutterTarget(SimulatorTarget(host)),
);

final class TestSwiftPmSdkIdentity implements SwiftPmSdkIdentity {
  const TestSwiftPmSdkIdentity({this.platformIdentity = 'test-platform'});
  @override
  final String platformIdentity;
  @override
  Future<Map<String, Object>> sdkBuildIdentity(String root) async => const {};
  @override
  Future<Map<String, Object>> hostToolchainIdentity() async => const {};
  @override
  Future<Map<String, Object>> swiftPmBuildToolchainIdentity({
    required String cCompilerPath,
    required String cxxCompilerPath,
    required String linkerPath,
    required String librarianPath,
  }) async => const {};
  @override
  Future<String?> hostToolchainMismatch(String root) async => null;
  @override
  String mismatchGuidance(String? detail) =>
      'After switching Swift, run xcross sdk install. ${detail ?? ''}';
}

SwiftPmRuntime<WindowsHost> testWindowsSimulatorSwiftPmRuntime() =>
    testWindowsSwiftPmRuntime(
      targetPolicy: (host) => SimulatorFlutterTarget(SimulatorTarget(host)),
    );

Log testSwiftPmLog() => Log(output: const TestLogOutput());

final class TestLogOutput implements LogOutput {
  const TestLogOutput();
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) {}
  @override
  void stderr(String message) {}
  @override
  void write(String message) {}
}

final class RecordingSwiftPmInteropBuild implements SwiftPmInteropBuild {
  RecordingSwiftPmInteropBuild({
    required Future<void> Function() build,
    required Future<void> Function(String) buildTarget,
    Future<void> Function()? repairConsumers,
  }) : _build = build,
       _buildTarget = buildTarget,
       _repairConsumers = repairConsumers;
  @override
  final command = SwiftPmBuildCommand(
    executable: 'fixture',
    arguments: const [],
    environment: const {},
    scratchPath: 'fixture',
    targetBuildDir: 'fixture',
    ownedRoots: const [],
    consumerProducts: const {},
  );
  final Future<void> Function() _build;
  final Future<void> Function(String) _buildTarget;
  final Future<void> Function()? _repairConsumers;
  @override
  Future<void> build() => _build();
  @override
  Future<void> buildTarget(String target) => _buildTarget(target);
  @override
  Future<void> repairConsumers() async {
    await _repairConsumers?.call();
  }
}

SwiftPmInteropBuildRecovery<MacOSHost> testPosixInteropRecovery(
  SwiftPmRuntime<MacOSHost> runtime,
  RecordingSwiftPmInteropBuild session,
) => SwiftPmInteropBuildRecovery(
  session: session,
  planReader: runtime.planReader,
  consumerRepair: runtime.consumerRepair,
  hostPolicy: runtime.hostPolicy,
  execution: RecordingPosixSwiftPmExecution(session),
);
SwiftPmInteropBuildRecovery<WindowsHost> testWindowsInteropRecovery(
  SwiftPmRuntime<WindowsHost> runtime,
  RecordingSwiftPmInteropBuild session,
) => SwiftPmInteropBuildRecovery(
  session: session,
  planReader: runtime.planReader,
  consumerRepair: runtime.consumerRepair,
  hostPolicy: runtime.hostPolicy,
  execution: RecordingWindowsSwiftPmExecution(session),
);

final class RecordingPosixSwiftPmExecution
    implements SwiftPmBuildExecution<MacOSHost> {
  RecordingPosixSwiftPmExecution(this.session);
  final RecordingSwiftPmInteropBuild session;
  @override
  Future<void> execute(SwiftPmBuildCommand command) => session.build();
  @override
  Future<void> recoverInterop({
    required Set<String> emitted,
    required SwiftPmBuildCommand command,
    required Object error,
    required StackTrace stack,
  }) => Future<void>.error(error, stack);
}

final class RecordingWindowsSwiftPmExecution
    implements SwiftPmBuildExecution<WindowsHost> {
  RecordingWindowsSwiftPmExecution(this.session);
  final RecordingSwiftPmInteropBuild session;
  @override
  Future<void> execute(SwiftPmBuildCommand command) => session.build();
  @override
  Future<void> recoverInterop({
    required Set<String> emitted,
    required SwiftPmBuildCommand command,
    required Object error,
    required StackTrace stack,
  }) async {
    if (emitted.isEmpty) Error.throwWithStackTrace(error, stack);
    try {
      await session.repairConsumers();
    } on Object {
      Error.throwWithStackTrace(error, stack);
    }
    await session.build();
  }
}

WindowsSwiftPmPinnedDependencyResolver<WindowsHost> testWindowsPinnedResolver(
  SwiftPmRuntime<WindowsHost> runtime,
  SwiftPmGitPackageCloner repository,
) => WindowsSwiftPmPinnedDependencyResolver(
  runner: runtime.runner,
  fileSystem: runtime.artifactFileSystem,
  filesystem: runtime.filesystem,
  repository: repository,
  manifestNormalizer: runtime.checkoutManifestNormalizer,
);

final class RecordingSwiftPmGitPackageCloner
    implements SwiftPmGitPackageCloner {
  RecordingSwiftPmGitPackageCloner(this.clone);
  final Future<void> Function(String, String, String, String) clone;
  @override
  Future<void> cloneGitPackage(
    String git,
    String url,
    String ref,
    String destination,
  ) => clone(git, url, ref, destination);
}

SwiftPmInteropBuildRecovery<T>
testGenericInteropRecovery<T extends PlatformHostInterface>(
  SwiftPmRuntime<T> runtime,
  RecordingSwiftPmInteropBuild session,
) => SwiftPmInteropBuildRecovery(
  session: session,
  planReader: runtime.planReader,
  consumerRepair: runtime.consumerRepair,
  hostPolicy: runtime.hostPolicy,
  execution: runtime.buildExecution,
);

final class FixtureSwiftPmArchiveTransport implements SwiftPmArchiveTransport {
  FixtureSwiftPmArchiveTransport(List<int> bytes)
    : bytes = List.unmodifiable(bytes);
  final List<int> bytes;
  int calls = 0;
  @override
  Future<void> download(Uri url, File destination, int maximumBytes) async {
    if (bytes.length > maximumBytes) {
      throw StateError('fixture exceeds archive limit');
    }
    calls++;
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes);
  }
}

final class FixtureSwiftPmLlvmToolLookup<T extends PlatformHostInterface>
    implements SwiftPmLlvmToolLookup<T> {
  FixtureSwiftPmLlvmToolLookup({required this.runner, required this.find});
  @override
  final ProcessRunner<T> runner;
  final Future<String?> Function(String) find;
  @override
  Future<String?> locate(String name) => find(name);
}

SwiftPmToolchain<MacOSHost> testPosixToolchainLookup(
  SwiftPmRuntime<MacOSHost> runtime,
  Future<String?> Function(String) find,
) {
  final librarian = SwiftPmLibrarianResolver(
    runner: runtime.runner,
    filesystem: runtime.filesystem,
    lookup: FixtureSwiftPmLlvmToolLookup(runner: runtime.runner, find: find),
  );
  return SwiftPmToolchain(
    filesystem: runtime.filesystem,
    hostBuildServices: runtime.hostBuildServices,
    librarianResolver: librarian,
  );
}

SwiftPmToolchain<WindowsHost> testWindowsToolchainLookup(
  SwiftPmRuntime<WindowsHost> runtime,
  Future<String?> Function(String) find,
) {
  final librarian = SwiftPmLibrarianResolver(
    runner: runtime.runner,
    filesystem: runtime.filesystem,
    lookup: FixtureSwiftPmLlvmToolLookup(runner: runtime.runner, find: find),
  );
  final services = WindowsSwiftPmHostBuildServices(
    target: runtime.target,
    filesystem: runtime.filesystem,
    sdkIdentity: runtime.sdkIdentity,
    runner: runtime.runner,
    sdkRepository: runtime.sdkRepository,
    toolchainResolver: runtime.toolchainResolver,
    librarianResolver: librarian,
  );
  return SwiftPmToolchain(
    filesystem: runtime.filesystem,
    hostBuildServices: services,
    librarianResolver: librarian,
  );
}
