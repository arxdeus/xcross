import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/composition/apple_host.dart';
import 'package:apple_developer_kit/composition/native_library_loader.dart';
import 'package:cli_kit/host/shared/posix_privileges.dart';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/http/local_http.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:dart_mobile_device/host/linux/linux_device_host.dart';
import 'package:dart_mobile_device/shared/console/device_console.dart';
import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:darwin_sdk_kit/host/linux/linux_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/host/shared/darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/flutter/linux_flutter_feature_services.dart';
import 'package:xcross/src/composition/flutter/swiftpm_checkout.dart';
import 'package:xcross/src/composition/host_operations.dart';
import 'package:xcross/src/composition/xcross_application.dart';
import 'package:xcross/src/composition/xcross_host_context.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/linux/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/host/linux/runtime/compose_host_provider.dart';
import 'package:xcross/src/host/shared/config/posix_config_host.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart';
import 'package:xcross/src/host/shared/flutter/posix_flutter_sdk_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_copy_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_filesystem.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_attributes.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_link_creator.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_link_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_manifest_policy.dart';
import 'package:xcross/src/host/shared/runtime/unsupported_compose_simulator_capability.dart';
import 'package:xcross/src/host/shared/sdk/preserved_sdk_archive_links.dart';
import 'package:xcross/src/host/shared/tools/unsupported_swiftpm_gate.dart';
import 'package:xcross/src/shared/cli/basic/sdk_install.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/config/config_host.dart';
import 'package:xcross/src/shared/config/runtime_config.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_install_identity.dart';
import 'package:xcross/src/shared/flutter/vm_service_connector.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/tools/swiftpm_gate_operation.dart';
import 'package:xcross/src/shared/update/release_lookup.dart';
import 'package:xcross/src/shared/xcrun/cross_xcrun.dart';
import 'package:xcross/src/shared/xcrun/xcrun_operation.dart';
import 'package:xcross/src/target/iphone/sdk/iphone_sdk_metadata_platform.dart';
import 'package:xcross/src/target/simulator/sdk/simulator_sdk_metadata_platform.dart';

@internal
final class LinuxXcrossHostContext
    extends XcrossHostContext<LinuxHostInterface> {
  LinuxXcrossHostContext(
    this.host, {
    required this.setupConsole,
    required this.releaseLookup,
    required this.outputHasTerminal,
    required this.createHttpClient,
    required this.abi,
    required this.commandPrompt,
    required this.executable,
    required this.log,
    required this.stdinStream,
    required this.stdoutSink,
    required this.stderrSink,
    required this.downloader,
    required this.deviceConsole,
    required this.deviceSockets,
    required this.signingHttpClients,
    required this.createAppleHttpClient,
    required this.createLocalHttpClient,
    required this.vmOutput,
    this.processorCount = 1,
    this.hostname = 'xcross',
    this.localeName = 'en_US',
  });
  @override
  final LinuxHostInterface host;
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
  final DeviceSockets deviceSockets;
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
  final CommandPrompt commandPrompt;
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
      LinuxDarwinToolchainLocations(host);
  @override
  SwiftPmGateOperation get swiftPmGate => const UnsupportedSwiftPmGate('linux');

  @override
  XcrunOperation get xcrun => CrossXcrunOperation(
    this,
    host: host,
    executable: executable,
    output: stdoutSink,
    errors: stderrSink,
  );

  @override
  XcrossApplication<LinuxHostInterface> bind(
    XcrossRuntimeConfig config,
    ProcessRunner<LinuxHostInterface> runner,
    DarwinSdkRepository<LinuxHostInterface> repository,
    DarwinToolchainResolver<LinuxHostInterface> toolchain,
  ) {
    final localHttp = LocalHttp(host, createClient: createLocalHttpClient);
    final vmConnector = LocalVmServiceConnector(localHttp);
    final resolvedExecutable = config.roots?.xcross ?? executable;
    final pymd = Pymd(
      localHttp: localHttp,
      console: deviceConsole,
      runner,
      privileges: PosixPrivileges(runner),
      hostPolicy: LinuxDeviceHost(runner),
      hostname: hostname,
      executable: resolvedExecutable,
      pairingHome:
          host.environment.lookup(runner.effectiveEnvironment, 'HOME') ??
          host.environment.lookup(runner.effectiveEnvironment, 'USERPROFILE'),
    );
    final operations = linuxHostOperations(
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
      swiftToolchain: operations.swiftToolchain,
      swiftBuildTools: const ['swift', 'swiftc'],
      metadataPlatforms: [
        const IPhoneSdkMetadataPlatform<LinuxHostInterface>(),
        const SimulatorSdkMetadataPlatform<LinuxHostInterface>(),
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
    final checkoutParts =
        SwiftPmCheckoutAssemblyParts<LinuxHostInterface>.prepare(
          runner: runner,
          fileSystem: artifactFileSystem,
        );
    const checkoutAttributes = PosixSwiftPmCheckoutAttributes();
    final checkout = assembleSwiftPmCheckout<LinuxHostInterface>(
      parts: checkoutParts,
      gitPolicy: const PosixSwiftPmCheckoutGitPolicy(),
      fallback: PosixSwiftPmCheckoutFallback(
        fileSystem: artifactFileSystem,
        filesystem: checkoutParts.filesystem,
        graph: checkoutParts.graph,
      ),
      attributes: checkoutAttributes,
      linkCreator: PosixSwiftPmCheckoutLinkCreator(artifactFileSystem),
      environment: runner.effectiveEnvironment,
    );
    final checkoutManifestNormalizer =
        SwiftPmCheckoutManifestNormalizer<LinuxHostInterface>(
          fileSystem: artifactFileSystem,
          filesystem: checkoutParts.filesystem,
          attributes: checkoutAttributes,
          policy: PosixSwiftPmVendoredManifestPolicy(
            sourceNormalizer: checkoutParts.sourceNormalizer,
            sourceFallback: checkoutParts.sourceFallback,
          ),
        );
    final flutter = LinuxFlutterFeatureServices<LinuxHostInterface>(
      checkout: checkout,
      checkoutAttributes: checkoutAttributes,
      checkoutManifestNormalizer: checkoutManifestNormalizer,
      runner: runner,
      repository: repository,
      toolchain: toolchain,
      downloader: downloader,
      hostTools: LinuxNativeHostTools(host, runner),
      renderer: PosixAppleToolShimRenderer(host),
      sdkPolicy: PosixFlutterSdkPolicy(),
      swiftPmPolicy: const LinuxSwiftPmHostPolicy(),
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
    final runtime = XcrossRuntime(
      commandPrompt: commandPrompt,
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
      flutter: flutter,
      composeHostProvider: LinuxComposeHostProvider(host),
      composeSimulatorCapability: UnsupportedComposeSimulatorCapability(host),
      executable: resolvedExecutable,
      operations: operations,
      appleHostServices: createLinuxAppleHostServices(
        host,
        localeName: localeName,
        abi: abi,
      ),
      localHttp: localHttp,
      downloader: downloader,
      signingHttpClients: signingHttpClients,
      createAppleHttpClient: createAppleHttpClient,
      vmConnector: vmConnector,
      vmOutput: vmOutput,
      sdkInstall: installer,
      configPolicy: configPolicy,
      createNativeLibraryLoader: createLinuxNativeLibraryLoader,
    );
    return XcrossApplication(
      runtime: runtime,
      pymd: pymd,
      sockets: deviceSockets,
    );
  }
}
