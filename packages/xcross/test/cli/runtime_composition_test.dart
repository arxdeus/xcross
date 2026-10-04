import 'dart:ffi';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device_shared.dart'
    show Device, DeviceDiagnostics, DevicePreparation, TunnelAvailability;
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:xcross/src/composition/cli/runner.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/composition/xcross_application.dart';
import 'package:xcross/src/composition/xcross_runtime.dart';
import 'package:xcross/src/host/macos/target/simulator/runtime/compose_simulator_capability.dart';
import 'package:xcross/src/shared/cli/basic/auth_command.dart';
import 'package:xcross/src/shared/cli/basic/completion_command.dart';
import 'package:xcross/src/shared/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/cli/basic/update_command.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/cli/flutter/subcommands/dap_command.dart';
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/update/install_layout.dart';
import 'package:xcross/src/shared/update/release_lookup.dart';
import 'package:xcross/src/target/iphone/cli/basic/tunnel_command.dart';
import 'package:xcross/src/target/iphone/device/signing_http_client_factory.dart';

import 'runtime_fixture.dart';

void main() {
  test(
    'application rejects physical services from another configured runner',
    () {
      final application = testApplication();
      final other = testApplication();
      expect(application.pymd.runner, same(application.runtime.runner));
      expect(
        () => XcrossApplication(
          runtime: application.runtime,
          pymd: other.pymd,
          sockets: application.sockets,
        ),
        throwsArgumentError,
      );
    },
  );

  test('macOS simulator capability retains the selected signing port', () {
    final signing = RecordingSimulatorSigning(MacOSHost());
    final capability = MacOSComposeSimulatorCapability(signing);
    expect(capability.host, same(signing.host));
    expect(capability.requireSigning(), same(signing));
    expect(signing.calls, 0);
  });

  test(
    'doctor fails tool resolution before authentication or discovery',
    () async {
      final runtime = testRuntime();
      final diagnostics = FailingDeviceDiagnostics();
      var httpCalls = 0;
      final checks = DoctorEnvironmentChecks(
        hostPlatform: runtime.host,
        runner: runtime.runner,
        repository: runtime.sdkRepository,
        toolchain: runtime.darwinToolchain,
        deviceDiagnostics: diagnostics,
        buildPlatform: composePhysicalFeatures(runtime).target.buildPlatform,
        appleHostServices: runtime.appleHostServices,
        sdkMismatch: (_) => throw StateError('No SDK probe expected'),
        sdkToolchainIdentity: () =>
            throw StateError('No toolchain probe expected'),
        createAppleHttpClient: () {
          httpCalls++;
          throw StateError('No authentication HTTP expected');
        },
      );
      final result = await checks.run();
      expect(result, hasLength(1));
      expect(result.single.status, DoctorStatus.failure);
      expect(result.single.name, 'Device tools');
      expect(diagnostics.resolveCalls, 1);
      expect(diagnostics.discoveryCalls, 0);
      expect(httpCalls, 0);
    },
  );

  test('tunnel command selects only the requested preparation route', () async {
    final preparation = RecordingDevicePreparation();
    final runner = CommandRunner<void>('xcross', 'test')
      ..addCommand(TunnelCommand(preparation));
    await runner.run(['tunnel']);
    expect(preparation.calls, ['usb']);
    await runner.run(['tunnel', '--wifi']);
    expect(preparation.calls, ['usb', 'wireless']);
  });

  test('DAP command retains only its explicitly supplied tunnel probe', () {
    final availability = RecordingTunnelAvailability();
    final command = DapCommand(testRuntime(), tunnelAvailability: availability);
    expect(command.tunnelAvailability, same(availability));
    expect(availability.calls, 0);
  });

  test(
    'non-macOS simulator diagnostic precedes unsupported ARM64 host resolution',
    () {
      final runtime = testRuntime(architecture: 'arm64');
      final simulator = composeBuildFeatures('simulator', runtime);
      expect(simulator.flutterRuntime.host, same(runtime.host));
      expect(
        () => simulator.composeOperation,
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('only on macOS'),
          ),
        ),
      );
    },
  );

  test(
    'auth delegates secure input failure before network or ADI access',
    () async {
      final failure = XcrossError(
        'password prompt requires an interactive terminal.',
      );
      final prompt = RecordingGuardPrompt(
        interactive: false,
        secretError: failure,
      );
      final runtime = testRuntime(commandPrompt: prompt);
      final command = AuthCommand(
        log: runtime.log,
        commandPrompt: prompt,
        hostServices: runtime.appleHostServices,
        createHttpClient: () => throw StateError('No Apple HTTP call expected'),
        createAdiHttpClient: () =>
            throw StateError('No ADI HTTP call expected'),
        createNativeLibraryLoader: () =>
            throw StateError('No native load expected'),
      );
      final runner = CommandRunner<void>('xcross', 'test')..addCommand(command);
      await expectLater(
        runner.run(['auth', '--apple-id', 'fixture@example.test']),
        throwsA(same(failure)),
      );
      expect(prompt.messages, ['secret:Password: :password']);
    },
  );

  test(
    'update confirmation uses injected prompt and preserves default refusal',
    () async {
      final prompt = RecordingGuardPrompt(interactive: true, answers: ['no']);
      final runtime = testRuntime(commandPrompt: prompt);
      var installed = false;
      final command = UpdateCommand.withSeams(
        runtime,
        latestTagLookup: () async => '1.2.0',
        currentVersion: () => '1.0.0',
        currentIsReleased: () => true,
        hasNativeLibraries: (_) => true,
        assetName: () => 'fixture.zip',
        resolveInstallLayout: () => InstallLayout(
          host: runtime.host,
          binaryPath: '/fixture/bin/xcross',
          binDir: '/fixture/bin',
          libDir: '/fixture/lib',
        ),
        installRelease: ({required layout, required tag}) async {
          installed = true;
        },
        refreshSetupScript: () async =>
            throw StateError('No setup update expected'),
      );
      final runner = CommandRunner<void>('xcross', 'test')..addCommand(command);
      await runner.run(['update']);
      expect(installed, isFalse);
      expect(prompt.messages, ['line:Update xcross to 1.2.0? [y/N] ']);
    },
  );

  test(
    'completion writes its script only to the supplied output collaborator',
    () {
      final output = StringBuffer();
      CompletionCommand(write: output.write).run();
      expect(output.toString(), contains('xcross'));
      expect(output.length, greaterThan(100));
    },
  );

  test(
    'DAP test adapter options and machine stdout survive global verbose flags',
    () {
      final runner = XcrossCli.buildRunner(
        testApplication(),
        configTerminal: TestTerminal(),
      );
      const arguments = [
        '--verbose',
        'flutter',
        'dap',
        '--test',
        '--',
        '--machine',
      ];
      final dap = runner.argParser.parse(arguments).command!.command!;
      expect(dap.flag('test'), isTrue);
      expect(dap.rest, ['--machine']);
      expect(XcrossCli.ownsMachineStdout(arguments, runner), isTrue);
      expect(
        XcrossCli.ownsMachineStdout(['--verbose', 'completion'], runner),
        isTrue,
      );
      expect(
        XcrossCli.ownsMachineStdout(['--verbose', 'doctor'], runner),
        isFalse,
      );
    },
  );

  for (final (name, abi, createHost)
      in <(String, Abi, PlatformHostInterface Function(String))>[
        (
          'windows',
          Abi.windowsX64,
          (root) => WindowsHost(
            architecture: 'x64',
            environment: {'USERPROFILE': root, 'XCROSS_NO_UPDATE_CHECK': '1'},
            fileSystem: LinuxHost(currentDirectory: root).fileSystem,
          ),
        ),
        (
          'macos',
          Abi.macosArm64,
          (root) => MacOSHost(
            architecture: 'arm64',
            currentDirectory: root,
            environment: {'HOME': root, 'XCROSS_NO_UPDATE_CHECK': '1'},
          ),
        ),
      ]) {
    test(
      '$name production context retains captured generic feature policies',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'xcross-$name-runtime-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final host = createHost(directory.path);
        final log = testLog();
        final context = composeXcrossHost(
          host,
          abi: abi,
          executable: '/test/xcross',
          commandPrompt: TestCommandPrompt(),
          log: log,
          stdinStream: const Stream.empty(),
          stdoutSink: testByteSink(),
          stderrSink: testByteSink(),
          downloader: Downloader(createClient: HttpClient.new, log: log),
          deviceConsole: TestDeviceConsole(),
          deviceSockets: const TestDeviceSockets(),
          signingHttpClients: const HttpSigningClientFactory(),
          createAppleHttpClient: http.Client.new,
          createHttpClient: http.Client.new,
          createLocalHttpClient: HttpClient.new,
          vmOutput: VmServiceOutput(
            output: StringBuffer(),
            errors: StringBuffer(),
          ),
          setupConsole: SetupConsole(
            hasTerminal: false,
            readLine: () => null,
            output: testByteSink(),
          ),
          releaseLookup: const ReleaseLookup(createClient: HttpClient.new),
          outputHasTerminal: false,
        );
        final physical = await context.createBuildFeatures('iphone');
        expect(physical.flutterRuntime.host, same(host));
        expect(physical.composeOperation.context.runner.host, same(host));
        final simulator = await context.createBuildFeatures('simulator');
        expect(simulator.flutterRuntime.host, same(host));
        if (name == 'macos') {
          expect(simulator.composeOperation.context.runner.host, same(host));
        } else {
          expect(() => simulator.composeOperation, throwsA(isA<XcrossError>()));
        }
        expect(
          (await context.createCommandRunner(
            configTerminal: TestTerminal(),
          )).commands,
          contains('flutter'),
        );
      },
    );
  }

  test(
    'widened production context retains concrete host generic during composition',
    () async {
      final directory = Directory.systemTemp.createTempSync('xcross-runtime-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final host = LinuxHost(
        architecture: 'x64',
        currentDirectory: directory.path,
        temporaryDirectory: directory.path,
        environment: {'HOME': directory.path, 'XCROSS_NO_UPDATE_CHECK': '1'},
      );
      final log = testLog();
      final context = composeXcrossHost(
        host,
        abi: Abi.linuxX64,
        executable: '/test/xcross',
        commandPrompt: TestCommandPrompt(),
        log: log,
        stdinStream: const Stream.empty(),
        stdoutSink: testByteSink(),
        stderrSink: testByteSink(),
        downloader: Downloader(createClient: HttpClient.new, log: log),
        deviceConsole: TestDeviceConsole(),
        deviceSockets: const TestDeviceSockets(),
        signingHttpClients: const HttpSigningClientFactory(),
        createAppleHttpClient: http.Client.new,
        createHttpClient: http.Client.new,
        createLocalHttpClient: HttpClient.new,
        vmOutput: VmServiceOutput(
          output: StringBuffer(),
          errors: StringBuffer(),
        ),
        setupConsole: SetupConsole(
          hasTerminal: false,
          readLine: () => null,
          output: testByteSink(),
        ),
        releaseLookup: const ReleaseLookup(createClient: HttpClient.new),
        outputHasTerminal: false,
      );
      final physical = await context.createBuildFeatures('iphone');
      expect(physical.flutterRuntime.host, same(host));
      expect(physical.composeOperation.context.runner.host, same(host));
      final simulator = await context.createBuildFeatures('simulator');
      expect(simulator.flutterRuntime.host, same(host));
      expect(() => simulator.composeOperation, throwsA(isA<XcrossError>()));
      final commands = await context.createCommandRunner(
        configTerminal: TestTerminal(),
      );
      expect(commands.commands, contains('flutter'));
      expect(
        await context.runApplication([
          'flutter',
          'build',
          '--profile',
        ], configTerminal: TestTerminal()),
        64,
      );
    },
  );

  test('feature runtimes retain one host and target identity', () {
    final runtime = testRuntime();
    final physical = composePhysicalFeatures(runtime);
    final simulator = composeBuildFeatures('simulator', runtime);
    expect(identical(physical.target.host, runtime.host), isTrue);
    expect(identical(simulator.target.host, runtime.host), isTrue);
    expect(identical(physical.flutterRuntime.target, physical.target), isTrue);
    expect(
      identical(simulator.flutterRuntime.target, simulator.target),
      isTrue,
    );
    expect(identical(physical.flutterRuntime.runner, runtime.runner), isTrue);
    final physicalServices = physical.flutterRuntime.plugins.runtime;
    final simulatorServices = simulator.flutterRuntime.plugins.runtime;
    expect(
      physicalServices.toolchain.hostBuildServices.target,
      same(physical.target),
    );
    expect(
      simulatorServices.toolchain.hostBuildServices.target,
      same(simulator.target),
    );
    expect(
      physicalServices.gatePlatform.fileSystem,
      same(physicalServices.artifactFileSystem),
    );
    expect(
      physicalServices.gatePlatform.matchesTarget(
        physical.flutterRuntime.policy,
      ),
      isTrue,
    );
    expect(
      simulatorServices.gatePlatform.matchesTarget(
        simulator.flutterRuntime.policy,
      ),
      isTrue,
    );
    expect(physical.target.buildPlatform.sdkName, 'iphoneos');
    expect(simulator.target.buildPlatform.sdkName, 'iphonesimulator');
  });

  test(
    'Linux simulator Flutter artifact runtime is not rejected with Compose',
    () {
      final features = composeBuildFeatures('simulator', testRuntime());
      expect(
        features.flutterRuntime.target.buildPlatform.sdkName,
        'iphonesimulator',
      );
      expect(() => features.composeOperation, throwsA(isA<XcrossError>()));
    },
  );

  test(
    'unsupported Compose architecture does not poison Flutter or CLI startup',
    () {
      final application = testApplication(architecture: 'arm64');
      final runtime = application.runtime;
      final physical = composePhysicalFeatures(runtime);
      expect(physical.flutterRuntime.host.architecture, 'arm64');
      expect(
        XcrossCli.buildRunner(
          application,
          configTerminal: TestTerminal(),
        ).commands,
        contains('flutter'),
      );
      expect(() => physical.composeOperation, throwsA(isA<XcrossError>()));
    },
  );

  test(
    'target normalizer rejects unknown platforms and simulator IPA early',
    () {
      final runtime = testRuntime();
      expect(
        () => composeBuildFeatures('watchos', runtime),
        throwsA(isA<XcrossError>()),
      );
      expect(
        () => composeBuildFeatures('simulator', runtime, ipa: true),
        throwsA(isA<XcrossError>()),
      );
    },
  );

  test('distinct CPU snapshots reach physical Compose contexts', () {
    final first = testRuntime(processorCount: 3);
    final second = testRuntime(processorCount: 11);
    expect(
      composePhysicalFeatures(first).composeOperation.context.processorCount,
      3,
    );
    expect(
      composePhysicalFeatures(second).composeOperation.context.processorCount,
      11,
    );
    expect(identical(first.log, second.log), isFalse);
  });

  test('runtime rejects a different host instance of the same host type', () {
    final runtime = testRuntime();
    final other = ProcessRunner<LinuxHostInterface>(
      LinuxHost(),
      log: runtime.log,
      stdinStream: const Stream.empty(),
      stdoutSink: testByteSink(),
      stderrSink: testByteSink(),
    );
    expect(() => copyRuntime(runtime, runner: other), throwsArgumentError);
  });

  test('runtime rejects a second configured runner sharing the host', () {
    final runtime = testRuntime();
    final other = ProcessRunner(
      runtime.host,
      log: runtime.log,
      stdinStream: const Stream.empty(),
      stdoutSink: testByteSink(),
      stderrSink: testByteSink(),
    );
    expect(() => copyRuntime(runtime, runner: other), throwsArgumentError);
  });

  test('runtime rejects a repository with a different session logger', () {
    final runtime = testRuntime();
    final repository = DarwinSdkRepository(runtime.host, log: testLog());
    expect(
      () => copyRuntime(runtime, repository: repository),
      throwsArgumentError,
    );
  });

  test(
    'CLI usage failures reach the supplied sink without process stderr',
    () async {
      final application = testApplication(
        environment: const {'XCROSS_NO_UPDATE_CHECK': '1'},
      );
      final runtime = application.runtime;
      final code = await XcrossCli.run(
        ['flutter', 'build', '--profile'],
        application,
        configTerminal: TestTerminal(),
      );
      expect(code, 64);
      expect(
        (runtime.log.output as TestLogOutput).messages,
        contains(contains('support debug mode only')),
      );
    },
  );
}

XcrossRuntime<LinuxHostInterface> copyRuntime(
  XcrossRuntime<LinuxHostInterface> runtime, {
  ProcessRunner<LinuxHostInterface>? runner,
  DarwinSdkRepository<LinuxHostInterface>? repository,
}) => XcrossRuntime(
  config: runtime.config,
  commandPrompt: runtime.commandPrompt,
  input: runtime.input,
  output: runtime.output,
  errors: runtime.errors,
  setupConsole: runtime.setupConsole,
  releaseLookup: runtime.releaseLookup,
  outputHasTerminal: runtime.outputHasTerminal,
  createHttpClient: runtime.createHttpClient,
  runner: runner ?? runtime.runner,
  processorCount: runtime.processorCount,
  sdkRepository: repository ?? runtime.sdkRepository,
  darwinToolchain: runtime.darwinToolchain,
  flutter: runtime.flutter,
  composeHostProvider: runtime.composeHostProvider,
  composeSimulatorCapability: runtime.composeSimulatorCapability,
  executable: runtime.executable,
  operations: runtime.operations,
  appleHostServices: runtime.appleHostServices,
  sdkInstall: runtime.sdkInstall,
  configPolicy: runtime.configPolicy,
  createNativeLibraryLoader: runtime.createNativeLibraryLoader,
  createAppleHttpClient: runtime.createAppleHttpClient,
  vmConnector: runtime.vmConnector,
  vmOutput: runtime.vmOutput,
  downloader: runtime.downloader,
  localHttp: runtime.localHttp,
  signingHttpClients: runtime.signingHttpClients,
);

final class RecordingGuardPrompt implements CommandPrompt {
  RecordingGuardPrompt({
    required this.interactive,
    List<String?> answers = const [],
    this.secretError,
  }) : answers = List.of(answers);
  final bool interactive;
  final Exception? secretError;
  final List<String?> answers;
  final messages = <String>[];
  @override
  bool get isInteractive => interactive;
  @override
  void write(String value) => messages.add(value);
  @override
  String? readLine(String prompt) {
    messages.add('line:$prompt');
    return answers.isEmpty ? null : answers.removeAt(0);
  }

  @override
  String? readSecret(String prompt, {required String valueName}) {
    messages.add('secret:$prompt:$valueName');
    if (secretError case final error?) throw error;
    return answers.isEmpty ? null : answers.removeAt(0);
  }
}

final class RecordingSimulatorSigning
    implements ComposeSimulatorSigning<MacOSHostInterface> {
  RecordingSimulatorSigning(this.host);
  @override
  final MacOSHostInterface host;
  int calls = 0;
  @override
  Future<void> signBundle(String appPath) async {
    calls++;
  }
}

final class FailingDeviceDiagnostics implements DeviceDiagnostics {
  int resolveCalls = 0;
  int discoveryCalls = 0;
  @override
  Future<String> resolveExecutable() {
    resolveCalls++;
    throw StateError('Fixture executable unavailable');
  }

  @override
  Future<List<Device>> devices() {
    discoveryCalls++;
    throw StateError('Discovery must not run');
  }

  @override
  Future<int?> osMajorVersion(Device device) =>
      throw StateError('Version probe must not run');
}

final class RecordingDevicePreparation implements DevicePreparation {
  final List<String> calls = [];
  @override
  Future<void> prepare() async {
    calls.add('usb');
  }

  @override
  Future<void> prepareWireless() async {
    calls.add('wireless');
  }
}

final class RecordingTunnelAvailability implements TunnelAvailability {
  int calls = 0;
  @override
  Future<bool> isReachable() async {
    calls++;
    return true;
  }
}
