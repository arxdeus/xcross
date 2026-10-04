import 'dart:ffi';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/dart_mobile_device_shared.dart'
    show DeviceConsole, DeviceSockets;
import 'package:http/http.dart' as http;
import 'package:xcross/src/composition/host/linux_xcross_context.dart';
import 'package:xcross/src/composition/host/macos_xcross_context.dart';
import 'package:xcross/src/composition/host/windows_xcross_context.dart';
import 'package:xcross/src/composition/xcross_host_context.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';
import 'package:xcross/src/shared/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/update/release_lookup.dart';

export 'package:xcross/src/composition/native_runtime.dart';

XcrossHostContext<PlatformHostInterface> composeXcrossHost(
  PlatformHostInterface host, {
  required Abi abi,
  required CommandPrompt commandPrompt,
  required SetupConsole setupConsole,
  required ReleaseLookup releaseLookup,
  required bool outputHasTerminal,
  required http.Client Function() createHttpClient,
  required String executable,
  required Log log,
  required Stream<List<int>> stdinStream,
  required IOSink stdoutSink,
  required IOSink stderrSink,
  required Downloader downloader,
  required DeviceConsole deviceConsole,
  required DeviceSockets deviceSockets,
  required SigningHttpClientFactory signingHttpClients,
  required http.Client Function() createAppleHttpClient,
  required HttpClient Function() createLocalHttpClient,
  required VmServiceOutput vmOutput,
  int processorCount = 1,
  String hostname = 'xcross',
  String localeName = 'en_US',
}) => switch (host) {
  WindowsHostInterface() => WindowsXcrossHostContext(
    host,
    abi: abi,
    commandPrompt: commandPrompt,
    setupConsole: setupConsole,
    releaseLookup: releaseLookup,
    outputHasTerminal: outputHasTerminal,
    createHttpClient: createHttpClient,

    executable: executable,
    log: log,
    stdinStream: stdinStream,
    stdoutSink: stdoutSink,
    stderrSink: stderrSink,
    downloader: downloader,
    deviceConsole: deviceConsole,
    deviceSockets: deviceSockets,
    signingHttpClients: signingHttpClients,
    createAppleHttpClient: createAppleHttpClient,
    createLocalHttpClient: createLocalHttpClient,
    vmOutput: vmOutput,
    processorCount: processorCount,
    hostname: hostname,
    localeName: localeName,
  ),
  LinuxHostInterface() => LinuxXcrossHostContext(
    host,
    abi: abi,
    commandPrompt: commandPrompt,
    setupConsole: setupConsole,
    releaseLookup: releaseLookup,
    outputHasTerminal: outputHasTerminal,
    createHttpClient: createHttpClient,

    executable: executable,
    log: log,
    stdinStream: stdinStream,
    stdoutSink: stdoutSink,
    stderrSink: stderrSink,
    downloader: downloader,
    deviceConsole: deviceConsole,
    deviceSockets: deviceSockets,
    signingHttpClients: signingHttpClients,
    createAppleHttpClient: createAppleHttpClient,
    createLocalHttpClient: createLocalHttpClient,
    vmOutput: vmOutput,
    processorCount: processorCount,
    hostname: hostname,
    localeName: localeName,
  ),
  MacOSHostInterface() => MacOSXcrossHostContext(
    host,
    abi: abi,
    commandPrompt: commandPrompt,
    setupConsole: setupConsole,
    releaseLookup: releaseLookup,
    outputHasTerminal: outputHasTerminal,
    createHttpClient: createHttpClient,

    executable: executable,
    log: log,
    stdinStream: stdinStream,
    stdoutSink: stdoutSink,
    stderrSink: stderrSink,
    downloader: downloader,
    deviceConsole: deviceConsole,
    deviceSockets: deviceSockets,
    signingHttpClients: signingHttpClients,
    createAppleHttpClient: createAppleHttpClient,
    createLocalHttpClient: createLocalHttpClient,
    vmOutput: vmOutput,
    processorCount: processorCount,
    hostname: hostname,
    localeName: localeName,
  ),
  _ => throw UnsupportedError('Unsupported xcross host'),
};
