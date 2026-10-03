import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:http/http.dart' as http;
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/composition/flutter/swiftpm_checkout.dart';
import 'package:xcross/src/composition/flutter/windows_flutter_feature_services.dart';
import 'package:xcross/src/composition/host_operations.dart';
import 'package:xcross/src/composition/xcross_host_context.dart';
import 'package:xcross/src/config/runtime_config.dart';
import 'package:xcross/src/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart';
import 'package:xcross/src/host/shared/runtime/unsupported_compose_simulator_capability.dart';
import 'package:xcross/src/host/windows/config/windows_config_host.dart';
import 'package:xcross/src/host/windows/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_link_creator.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_link_policy.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/checkout_manifest_policy.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/host/windows/flutter/windows_flutter_sdk_policy.dart';
import 'package:xcross/src/host/windows/runtime/compose_host_provider.dart';
import 'package:xcross/src/host/windows/sdk/materialized_sdk_archive_links.dart';
import 'package:xcross/src/host/windows/tools/windows_swiftpm_gate.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/config/config_host.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_install_identity.dart';
import 'package:xcross/src/shared/flutter/vm_service_connector.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/tools/swiftpm_gate_operation.dart';
import 'package:xcross/src/shared/xcrun/cross_xcrun.dart';
import 'package:xcross/src/shared/xcrun/xcrun_operation.dart';
import 'package:xcross/src/target/iphone/sdk/iphone_sdk_metadata_platform.dart';
import 'package:xcross/src/target/simulator/sdk/simulator_sdk_metadata_platform.dart';
import 'package:xcross/src/update/release_lookup.dart';

final class WindowsXcrossHostContext
    extends XcrossHostContext<WindowsHostInterface> {
  WindowsXcrossHostContext(
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
    required this.signingHttpClients,
    required this.createAppleHttpClient,
    required this.createLocalHttpClient,
    required this.vmOutput,
    this.processorCount = 1,
    this.hostname = 'xcross',
    this.localeName = 'en_US',
  });
  @override
  final WindowsHostInterface host;
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
  ConfigHostInterface get configPolicy => const WindowsConfigHost();
  @override
  DarwinToolchainLocationsInterface get toolchainLocations =>
      WindowsDarwinToolchainLocations(host);
  @override
  SwiftPmGateOperation get swiftPmGate => WindowsSwiftPmGate(this);

  @override
  XcrunOperation get xcrun => CrossXcrunOperation(
    this,
    executable: executable,
    output: stdoutSink,
    errors: stderrSink,
  );

  @override
  XcrossRuntime<WindowsHostInterface> bind(
    XcrossRuntimeConfig config,
    ProcessRunner<WindowsHostInterface> runner,
    DarwinSdkRepository<WindowsHostInterface> repository,
    DarwinToolchainResolver<WindowsHostInterface> toolchain,
  ) {
    final localHttp = LocalHttp(host, createClient: createLocalHttpClient);
    final vmConnector = LocalVmServiceConnector(localHttp);
    final resolvedExecutable = config.roots?.xcross ?? executable;
    final pymd = Pymd(
      localHttp: localHttp,
      console: deviceConsole,
      runner,
      privileges: WindowsPrivileges(runner),
      hostPolicy: WindowsDeviceHost(runner),
      hostname: hostname,
      executable: resolvedExecutable,
      pairingHome:
          host.environment.lookup(runner.effectiveEnvironment, 'HOME') ??
          host.environment.lookup(runner.effectiveEnvironment, 'USERPROFILE'),
    );
    final operations = windowsHostOperations(
      host,
      runner,
      toolchain,
      pymd,
      WindowsPrivileges(runner),
      setupConsole,
    );
    final installer = SdkInstall(
      runner,
      repository,
      links: MaterializedSdkArchiveLinks(host),
      swiftInstallGuidance: operations.swiftInstallGuidance,
      swiftBuildTools: const ['swift-package', 'swift-build', 'swiftc'],
      metadataPlatforms: [
        const IPhoneSdkMetadataPlatform<WindowsHostInterface>(),
        const SimulatorSdkMetadataPlatform<WindowsHostInterface>(),
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
    final artifactFileSystem = WindowsSwiftPmArtifactFileSystem(host, runner);
    final publicationCoordinator = SwiftPmPublicationCoordinator(
      locks: FileSwiftPmPublicationLockProvider(artifactFileSystem),
      pathKey: host.paths.pathKey,
    );
    final transport = HttpSwiftPmArchiveTransport(
      createClient: localHttp.client,
    );
    final copyPolicy = WindowsSwiftPmArtifactCopyPolicy(
      fileSystem: artifactFileSystem,
      startProcess: (executable, arguments) async =>
          RunnerBinaryCopyProcess(await runner.start(executable, arguments)),
    );
    final checkoutParts =
        SwiftPmCheckoutAssemblyParts<WindowsHostInterface>.prepare(
          runner: runner,
          fileSystem: artifactFileSystem,
        );
    final checkoutAttributes = WindowsSwiftPmCheckoutAttributes(
      runner,
      fileSystem: artifactFileSystem,
    );
    late final nativeLinks = WindowsSwiftPmNativeLinkApi(
      DynamicLibrary.open('kernel32.dll'),
    );
    final checkout = assembleSwiftPmCheckout<WindowsHostInterface>(
      parts: checkoutParts,
      gitPolicy: WindowsSwiftPmCheckoutGitPolicy(
        symlinks: checkoutParts.symlinks,
      ),
      fallback: WindowsSwiftPmCheckoutFallback(
        runner: runner,
        fileSystem: artifactFileSystem,
        filesystem: checkoutParts.filesystem,
        stamps: checkoutParts.stamps,
        graph: checkoutParts.graph,
      ),
      attributes: checkoutAttributes,
      linkCreator: WindowsSwiftPmCheckoutLinkCreator(
        fileSystem: artifactFileSystem,
        createLink: (link, target, flags) =>
            nativeLinks.createLink(link, target, flags),
        lastError: () => nativeLinks.lastError(),
      ),
      environment: runner.effectiveEnvironment,
    );
    final checkoutManifestNormalizer =
        SwiftPmCheckoutManifestNormalizer<WindowsHostInterface>(
          fileSystem: artifactFileSystem,
          filesystem: checkoutParts.filesystem,
          attributes: checkoutAttributes,
          policy: WindowsSwiftPmVendoredManifestPolicy(
            sourceNormalizer: checkoutParts.sourceNormalizer,
            sourceFallback: checkoutParts.sourceFallback,
          ),
        );
    final flutter = WindowsFlutterFeatureServices<WindowsHostInterface>(
      checkout: checkout,
      checkoutAttributes: checkoutAttributes,
      checkoutManifestNormalizer: checkoutManifestNormalizer,
      runner: runner,
      repository: repository,
      toolchain: toolchain,
      downloader: downloader,
      hostTools: WindowsNativeHostTools(host, runner),
      renderer: WindowsAppleToolShimRenderer(host),
      sdkPolicy: WindowsFlutterSdkPolicy(),
      swiftPmPolicy: WindowsSwiftPmHostPolicy(runner),
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
      pymd: pymd,
      flutter: flutter,
      composeHostProvider: WindowsComposeHostProvider(host, resolvedExecutable),
      composeSimulatorCapability: UnsupportedComposeSimulatorCapability(host),
      executable: resolvedExecutable,
      operations: operations,
      appleHostServices: createWindowsAppleHostServices(
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
      createNativeLibraryLoader: createWindowsNativeLibraryLoader,
    );
  }
}
