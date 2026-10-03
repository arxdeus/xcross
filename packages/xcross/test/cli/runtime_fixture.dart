import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart' show DeviceConsole;
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:http/http.dart' as http;
import 'package:xcross/src/composition/host/linux_xcross_context.dart';
import 'package:xcross/src/config/config.dart';
import 'package:xcross/src/config/runtime_config.dart';
import 'package:xcross/src/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/target/iphone/device/signing_http_client_factory.dart';
import 'package:xcross/src/update/release_lookup.dart';

import '../log_fixture.dart';

export '../log_fixture.dart';

XcrossRuntime<LinuxHostInterface> testRuntime({
  XcrossConfig? configuration,
  Map<String, String> environment = const {},
  int processorCount = 1,
  String architecture = 'x64',
}) {
  final host = LinuxHost(environment: environment, architecture: architecture);
  final log = testLog();
  final context = LinuxXcrossHostContext(
    host,
    abi: Abi.linuxX64,
    setupConsole: SetupConsole(
      hasTerminal: false,
      readLine: () => null,
      output: testByteSink(),
    ),
    releaseLookup: const ReleaseLookup(createClient: HttpClient.new),
    outputHasTerminal: false,
    createHttpClient: http.Client.new,
    executable: '/test/xcross',
    log: log,
    stdinStream: const Stream.empty(),
    stdoutSink: testByteSink(),
    stderrSink: testByteSink(),
    processorCount: processorCount,
    deviceConsole: TestDeviceConsole(),
    downloader: Downloader(createClient: HttpClient.new, log: log),
    createAppleHttpClient: AppleHttp.createAppleHttpClient,
    signingHttpClients: const HttpSigningClientFactory(),
    createLocalHttpClient: HttpClient.new,
    vmOutput: VmServiceOutput(output: StringBuffer(), errors: StringBuffer()),
  );
  final config = XcrossRuntimeConfig(
    config: configuration,
    configPath: null,
    processEnvironment: environment,
    childEnvironment: environment,
  );
  final runner = ProcessRunner(
    host,
    log: log,
    stdinStream: const Stream.empty(),
    stdoutSink: testByteSink(),
    stderrSink: testByteSink(),
    configuration: config.processConfiguration,
  );
  final repository = DarwinSdkRepository(host, log: log);
  return context.bind(
    config,
    runner,
    repository,
    DarwinToolchainResolver(runner, context.toolchainLocations),
  );
}

final class TestTerminal implements TuiTerminal {
  @override
  bool get isInteractive => false;
  @override
  void enterRaw() {}
  @override
  void leaveRaw() {}
  @override
  int readByte() => -1;
  @override
  String? readLine() => null;
  @override
  void write(String value) {}
}

final class TestDeviceConsole implements DeviceConsole {
  @override
  Stream<void> get interrupts => const Stream.empty();
  @override
  bool get inputHasTerminal => false;
  @override
  bool get outputHasTerminal => false;
  @override
  bool echoMode = true;
  @override
  bool lineMode = true;
  @override
  String? readLine() => null;
  @override
  void write(String value) {}
  @override
  void writeln(String value) {}
  @override
  void add(List<int> value) {}
}
