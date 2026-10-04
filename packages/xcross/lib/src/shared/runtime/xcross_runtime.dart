import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit_shared.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:http/http.dart' as http;
import 'package:xcross/src/shared/cli/basic/sdk_install.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/config/config_host.dart';
import 'package:xcross/src/shared/config/runtime_config.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';
import 'package:xcross/src/shared/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/shared/flutter/vm_service_connector.dart';
import 'package:xcross/src/shared/runtime/compose_host_provider.dart';
import 'package:xcross/src/shared/runtime/compose_simulator_capability.dart';
import 'package:xcross/src/shared/runtime/flutter_feature_services.dart';
import 'package:xcross/src/shared/setup/host_operations.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/update/release_lookup.dart';

final class XcrossRuntime<T extends PlatformHostInterface> {
  XcrossRuntime({
    required this.setupConsole,
    required this.releaseLookup,
    required this.outputHasTerminal,
    required this.createHttpClient,
    required this.config,
    required this.commandPrompt,
    required this.input,
    required this.output,
    required this.errors,
    required this.processorCount,
    required this.runner,
    required this.sdkRepository,
    required this.darwinToolchain,
    required this.flutter,
    required this.composeHostProvider,
    required this.composeSimulatorCapability,
    required this.executable,
    required this.operations,
    required this.appleHostServices,
    required this.sdkInstall,
    required this.configPolicy,
    required this.createNativeLibraryLoader,
    required this.createAppleHttpClient,
    required this.vmConnector,
    required this.vmOutput,
    required this.downloader,
    required this.localHttp,
    required this.signingHttpClients,
  }) {
    if (!identical(host, sdkRepository.host) ||
        !identical(host, darwinToolchain.host) ||
        !identical(host, flutter.runner.host) ||
        !identical(host, appleHostServices.host) ||
        !identical(host, sdkInstall.runner.host) ||
        !identical(host, localHttp.host) ||
        !identical(host, composeHostProvider.host) ||
        !identical(host, composeSimulatorCapability.host)) {
      throw ArgumentError('Runtime dependencies must share one selected host');
    }
    if (!identical(runner, darwinToolchain.runner) ||
        !identical(runner, flutter.runner) ||
        !identical(runner, sdkInstall.runner) ||
        !identical(log, sdkRepository.log) ||
        !identical(log, downloader.log)) {
      throw ArgumentError(
        'Runtime dependencies must share one configured runner and log',
      );
    }
  }
  final Stream<List<int>> input;
  final IOSink output;
  final IOSink errors;
  final SetupConsole setupConsole;
  final ReleaseLookup releaseLookup;
  final bool outputHasTerminal;
  final http.Client Function() createHttpClient;
  final CommandPrompt commandPrompt;
  final http.Client Function() createAppleHttpClient;
  final VmServiceConnector vmConnector;
  final VmServiceOutput vmOutput;
  final SigningHttpClientFactory signingHttpClients;
  final int processorCount;
  final LocalHttp<T> localHttp;
  final Downloader downloader;
  T get host => runner.host;
  Log get log => runner.log;
  final XcrossRuntimeConfig config;
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> sdkRepository;
  final DarwinToolchainResolver<T> darwinToolchain;
  final FlutterFeatureServices<T> flutter;
  final ComposeHostProvider<T> composeHostProvider;
  final ComposeSimulatorCapability<T> composeSimulatorCapability;
  final String executable;
  final HostOperations operations;
  final AppleHostServices appleHostServices;
  final SdkInstall<T> sdkInstall;
  final ConfigHostInterface configPolicy;
  final NativeLibraryLoader Function() createNativeLibraryLoader;
}
