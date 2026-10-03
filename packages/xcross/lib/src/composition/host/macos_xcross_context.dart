import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:http/http.dart' as http;
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/composition/host_operations.dart';
import 'package:xcross/src/composition/xcross_host_context.dart';
import 'package:xcross/src/config/runtime_config.dart';
import 'package:xcross/src/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/macos/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/host/macos/runtime/compose_feature_factory.dart';
import 'package:xcross/src/host/macos/xcrun/native_xcrun.dart';
import 'package:xcross/src/host/shared/config/posix_config_host.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart';
import 'package:xcross/src/host/shared/flutter/posix_flutter_sdk_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_copy_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_filesystem.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_build_execution.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_dependency_preparation.dart';
import 'package:xcross/src/host/shared/sdk/preserved_sdk_archive_links.dart';
import 'package:xcross/src/host/shared/tools/unsupported_swiftpm_gate.dart';
import 'package:xcross/src/shared/config/config_host.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_install_identity.dart';
import 'package:xcross/src/shared/flutter/vm_service_connector.dart';
import 'package:xcross/src/shared/runtime/flutter_feature_services.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/tools/swiftpm_gate_operation.dart';
import 'package:xcross/src/shared/xcrun/xcrun_operation.dart';
import 'package:xcross/src/target/iphone/sdk/iphone_sdk_metadata_platform.dart';
import 'package:xcross/src/target/simulator/sdk/simulator_sdk_metadata_platform.dart';
import 'package:xcross/src/update/release_lookup.dart';

final class MacOSXcrossHostContext
    extends XcrossHostContext<MacOSHostInterface> {
  MacOSXcrossHostContext(
    this.host, {
    required this.setupConsole,
    required this.releaseLookup,
    required this.outputHasTerminal,
    required this.createHttpClient,
    required this.abi,
    required this.executable,
    required this.log,
    required this.stdinStream,
    required this.stdoutSink,
    required this.stderrSink,
    required this.downloader,
    required this.deviceConsole,
    required this.signingHttpClients,
    required this.createAppleHttpClient,
    required this.createLocalHttpClient,
    required this.vmOutput,
    this.processorCount = 1,
    this.hostname = 'xcross',
    this.localeName = 'en_US',
  });
  @override
  final MacOSHostInterface host;
  @override
  final Abi abi;
  @override
  final Log log;
  @override
  final Stream<List<int>> stdinStream;
  @override
  final IOSink stdoutSink;
  @override
  final IOSink stderrSink;
  @override
  final int processorCount;
  @override
  final Downloader downloader;
  @override
  final DeviceConsole deviceConsole;
  @override
  final SigningHttpClientFactory signingHttpClients;
  @override
  final SetupConsole setupConsole;
  @override
  final ReleaseLookup releaseLookup;
  @override
  final bool outputHasTerminal;
  @override
  final http.Client Function() createHttpClient;
  @override
  final http.Client Function() createAppleHttpClient;
  @override
  final HttpClient Function() createLocalHttpClient;
  @override
  final VmServiceOutput vmOutput;
  @override
  final String executable;
  @override
  final String hostname;
  @override
  final String localeName;
  @override
  ConfigHostInterface get configPolicy => const PosixConfigHost();
  @override
  DarwinToolchainLocationsInterface get toolchainLocations =>
      MacOSDarwinToolchainLocations(host);
  @override
  SwiftPmGateOperation get swiftPmGate => const UnsupportedSwiftPmGate('macos');

  @override
  XcrunOperation get xcrun => NativeMacXcrun(host);

  @override
  XcrossRuntime<MacOSHostInterface> bind(
    XcrossRuntimeConfig config,
    ProcessRunner<MacOSHostInterface> runner,
    DarwinSdkRepository<MacOSHostInterface> repository,
    DarwinToolchainResolver<MacOSHostInterface> toolchain,
  ) {
    final localHttp = LocalHttp(host, createClient: createLocalHttpClient);
    final vmConnector = LocalVmServiceConnector(localHttp);
    final resolvedExecutable = config.roots?.xcross ?? executable;
    final pymd = Pymd(
      localHttp: localHttp,
      console: deviceConsole,
      runner,
      privileges: PosixPrivileges(runner),
      hostPolicy: MacOSDeviceHost(runner),
      hostname: hostname,
      executable: resolvedExecutable,
      pairingHome:
          host.environment.lookup(runner.effectiveEnvironment, 'HOME') ??
          host.environment.lookup(runner.effectiveEnvironment, 'USERPROFILE'),
    );
    final operations = macOSHostOperations(
      host,
      runner,
      toolchain,
      pymd,
      PosixPrivileges(runner),
      setupConsole,
    );
    final installer = SdkInstall(
      runner,
      repository,
      links: PreservedSdkArchiveLinks(host),
      swiftInstallGuidance: operations.swiftInstallGuidance,
      swiftBuildTools: const ['swift', 'swiftc'],
      metadataPlatforms: [
        const IPhoneSdkMetadataPlatform<MacOSHostInterface>(),
        const SimulatorSdkMetadataPlatform<MacOSHostInterface>(),
      ],
    );
    final resolution = FlutterResolutionConfiguration(
      executable: executable,
      launcher: config.roots?.xcross,
      xcrun: config.tool('xcrun'),
      root: config.roots?.flutterSdk,
      environmentRoot: config.config?.environment['FLUTTER_ROOT'] as String?,
      tool: config.tool('flutter'),
      declarative: config.isConfigured,
    );
    final artifactFileSystem = PosixSwiftPmArtifactFileSystem(host);
    final publicationCoordinator = SwiftPmPublicationCoordinator(
      locks: FileSwiftPmPublicationLockProvider(artifactFileSystem),
      pathKey: host.paths.pathKey,
    );
    final transport = HttpSwiftPmArchiveTransport(
      createClient: localHttp.client,
    );
    final copyPolicy = PosixSwiftPmArtifactCopyPolicy(artifactFileSystem);
    final flutter = FlutterFeatureServices<MacOSHostInterface>(
      buildExecution: PosixSwiftPmBuildExecution(runner: runner),
      dependencyPreparation:
          const PosixSwiftPmDependencyPreparation<MacOSHostInterface>(),
      runner: runner,
      repository: repository,
      toolchain: toolchain,
      downloader: downloader,
      hostTools: MacOSNativeHostTools(host, runner),
      renderer: PosixAppleToolShimRenderer(host),
      sdkPolicy: PosixFlutterSdkPolicy(),
      swiftPmPolicy: const MacOSSwiftPmHostPolicy(),
      artifactFileSystem: artifactFileSystem,
      publicationCoordinator: publicationCoordinator,
      transport: transport,
      copyPolicy: copyPolicy,
      sdkIdentity: SdkInstallSwiftPmIdentity(
        installer,
        platformIdentity: '${host.name}-${host.architecture}',
      ),
      resolution: resolution,
    );
    return XcrossRuntime(
      setupConsole: setupConsole,
      releaseLookup: releaseLookup,
      outputHasTerminal: outputHasTerminal,
      createHttpClient: createHttpClient,

      input: stdinStream,
      output: stdoutSink,
      errors: stderrSink,
      config: config,
      processorCount: processorCount,
      runner: runner,
      sdkRepository: repository,
      darwinToolchain: toolchain,
      pymd: pymd,
      flutter: flutter,
      compose: MacOSComposeFeatureFactory(host, runner),
      executable: resolvedExecutable,
      operations: operations,
      appleHostServices: createMacOSAppleHostServices(
        host,
        localeName: localeName,
        abi: abi,
        runner: runner,
      ),
      localHttp: localHttp,
      downloader: downloader,
      signingHttpClients: signingHttpClients,
      createAppleHttpClient: createAppleHttpClient,
      vmConnector: vmConnector,
      vmOutput: vmOutput,
      sdkInstall: installer,
      configPolicy: configPolicy,
      createNativeLibraryLoader: createMacOSNativeLibraryLoader,
    );
  }
}
