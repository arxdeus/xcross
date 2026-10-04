import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/tui/tui.dart';
import 'package:dart_mobile_device/shared/console/device_console.dart';
import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:darwin_sdk_kit/host/shared/darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/cli/runner.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/composition/xcross_application.dart';
import 'package:xcross/src/composition/xcrun_sdk.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/config/config_host.dart';
import 'package:xcross/src/shared/config/config_store.dart';
import 'package:xcross/src/shared/config/runtime_config.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';
import 'package:xcross/src/shared/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_evidence.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/tools/swiftpm_gate_operation.dart';
import 'package:xcross/src/shared/update/release_lookup.dart';
import 'package:xcross/src/shared/xcrun/xcrun_operation.dart';
import 'package:xcross/src/target/shared/runtime/build_features.dart';

@internal
abstract class XcrossHostContext<T extends PlatformHostInterface>
    implements XcrunRuntimeLoader, SwiftPmGateRuntimeLoader {
  T get host;
  CommandPrompt get commandPrompt;
  SetupConsole get setupConsole;
  ReleaseLookup get releaseLookup;
  bool get outputHasTerminal;
  http.Client Function() get createHttpClient;
  Stream<List<int>> get stdinStream;
  IOSink get stdoutSink;
  IOSink get stderrSink;
  int get processorCount;
  DeviceConsole get deviceConsole;
  DeviceSockets get deviceSockets;
  Downloader get downloader;
  SigningHttpClientFactory get signingHttpClients;
  http.Client Function() get createAppleHttpClient;
  HttpClient Function() get createLocalHttpClient;
  VmServiceOutput get vmOutput;
  Log get log;
  Abi get abi;
  String get executable;
  String get hostname;
  String get localeName;
  ConfigHostInterface get configPolicy;
  DarwinToolchainLocationsInterface get toolchainLocations;
  XcrunOperation get xcrun;
  SwiftPmGateOperation get swiftPmGate;

  Future<int> runApplication(
    List<String> args, {
    required TuiTerminal configTerminal,
  }) async =>
      XcrossCli.run<T>(args, await load(), configTerminal: configTerminal);

  Future<CommandRunner<void>> createCommandRunner({
    required TuiTerminal configTerminal,
  }) async =>
      XcrossCli.buildRunner<T>(await load(), configTerminal: configTerminal);

  Future<XcrossBuildFeatures<T>> createBuildFeatures(
    String targetPlatform, {
    bool ipa = false,
  }) async =>
      composeBuildFeatures<T>(targetPlatform, (await load()).runtime, ipa: ipa);

  Future<XcrossApplication<T>> load({
    XcrossConfigStore<T>? store,
    String? configDirectory,
  }) async {
    if (store != null && !identical(store.host, host)) {
      throw ArgumentError('Configuration store must share the selected host');
    }
    final config = await XcrossRuntimeConfig.load(
      host,
      policy: configPolicy,
      store: store,
      configDirectory: configDirectory,
    );
    final runner = ProcessRunner(
      host,
      log: log,
      stdinStream: stdinStream,
      stdoutSink: stdoutSink,
      stderrSink: stderrSink,
      configuration: config.processConfiguration,
    );
    final repository = DarwinSdkRepository(
      host,
      log: log,
      installBundle: config.roots?.darwinSdk,
    );
    final toolchain = DarwinToolchainResolver(runner, toolchainLocations);
    return bind(config, runner, repository, toolchain);
  }

  XcrossApplication<T> bind(
    XcrossRuntimeConfig config,
    ProcessRunner<T> runner,
    DarwinSdkRepository<T> repository,
    DarwinToolchainResolver<T> toolchain,
  );

  @override
  Future<SwiftPmGateServices> loadSwiftPmGate() async {
    final runtime = (await load()).runtime;
    final features = composePhysicalFeatures(runtime);
    final plugins = features.flutterRuntime.plugins.runtime;
    final sdk = runtime.sdkRepository.current();
    if (sdk == null) throw StateError('Darwin SDK is not installed');
    final sdkRoot = runtime.sdkRepository.iosSdk(
      sdk,
      target: features.target.buildPlatform,
    );
    return SwiftPmGateServices(
      cacheRoot:
          runtime.host.environment.lookup(
            runtime.runner.effectiveEnvironment,
            'XCROSS_CACHE_DIR',
          ) ??
          runtime.host.paths.cacheRoot,
      platformIdentity: plugins.sdkIdentity.platformIdentity,
      toolchainIdentity: () async => jsonEncode(
        await plugins.toolchain.resolveBuildToolchainIdentity(sdk),
      ),
      sdkIdentity: () async =>
          jsonEncode(await plugins.sdkIdentity.sdkBuildIdentity(sdkRoot)),
      verify:
          ({
            required mode,
            required root,
            required platformIdentity,
            required toolchainIdentity,
            required sdkIdentity,
          }) =>
              SwiftPmGateEvidence<T>(
                root,
                repository: runtime.sdkRepository,
                platform: plugins.gatePlatform,
                platformIdentity: plugins.sdkIdentity.platformIdentity,
                fileSystem: plugins.artifactFileSystem,
              ).verifies(
                mode: mode,
                platformIdentity: platformIdentity,
                toolchainIdentity: toolchainIdentity,
                sdkIdentity: sdkIdentity,
              ),
    );
  }

  @override
  Future<XcrunServices> loadXcrun({required String sdkName}) async {
    final runtime = (await load()).runtime;
    return XcrunServices(
      target: parseXcrunSdkName(sdkName),
      runner: runtime.runner,
      repository: runtime.sdkRepository,
      toolchain: runtime.darwinToolchain,
      normalizeExecutable: runtime.operations.normalizeExecutable,
    );
  }
}
