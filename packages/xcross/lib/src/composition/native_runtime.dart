import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit_shared.dart'
    show AppleHttpClientFactory;
import 'package:cli_kit/cli_kit.dart' show detectPlatformHostSnapshot;
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart'
    show NativeDeviceConsole, NativeDeviceSockets;
import 'package:http/http.dart' as http;
import 'package:xcross/src/composition/xcross_host_context.dart';
import 'package:xcross/src/composition/xcross_runtime.dart';
import 'package:xcross/src/host/shared/cli/native_command_prompt.dart';
import 'package:xcross/src/shared/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/update/release_lookup.dart';
import 'package:xcross/src/target/iphone/device/signing_http_client_factory.dart';

XcrossHostContext<PlatformHostInterface> createNativeXcrossContext() {
  final snapshot = detectPlatformHostSnapshot();
  final log = Log(
    output: StreamLogOutput(
      stdout: stdout,
      stderr: stderr,
      supportsAnsi: stdout.hasTerminal && stdout.supportsAnsiEscapes,
      terminalColumns: () => stdout.hasTerminal ? stdout.terminalColumns : 80,
    ),
  );
  return composeXcrossHost(
    snapshot.host,
    commandPrompt: NativeCommandPrompt(input: stdin, output: stdout),
    setupConsole: SetupConsole(
      hasTerminal: stdin.hasTerminal,
      readLine: stdin.readLineSync,
      output: stdout,
    ),
    releaseLookup: const ReleaseLookup(createClient: HttpClient.new),
    outputHasTerminal: stdout.hasTerminal,
    createHttpClient: http.Client.new,
    abi: snapshot.abi,
    processorCount: snapshot.processorCount,
    log: log,
    stdinStream: stdin,
    stdoutSink: stdout,
    stderrSink: stderr,
    deviceConsole: NativeDeviceConsole(input: stdin, output: stdout),
    deviceSockets: const NativeDeviceSockets(),
    downloader: Downloader(createClient: HttpClient.new, log: log),
    signingHttpClients: const HttpSigningClientFactory(),
    createAppleHttpClient: AppleHttpClientFactory(
      createSecurityContext: () => SecurityContext(withTrustedRoots: true),
      createHttpClient: (context) => HttpClient(context: context),
    ).createClient,
    createLocalHttpClient: HttpClient.new,
    vmOutput: VmServiceOutput(output: stdout, errors: stderr),
    executable: snapshot.resolvedExecutable,
    hostname: snapshot.localHostname,
    localeName: snapshot.localeName,
  );
}
