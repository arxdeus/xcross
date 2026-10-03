import 'dart:ffi';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:xcross/src/cli/runner.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/composition/xcross_runtime.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/target/iphone/device/signing_http_client_factory.dart';
import 'package:xcross/src/update/release_lookup.dart';

import 'runtime_fixture.dart';

void main() {
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
          log: log,
          stdinStream: const Stream.empty(),
          stdoutSink: testByteSink(),
          stderrSink: testByteSink(),
          downloader: Downloader(createClient: HttpClient.new, log: log),
          deviceConsole: TestDeviceConsole(),
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
        log: log,
        stdinStream: const Stream.empty(),
        stdoutSink: testByteSink(),
        stderrSink: testByteSink(),
        downloader: Downloader(createClient: HttpClient.new, log: log),
        deviceConsole: TestDeviceConsole(),
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
      final runtime = testRuntime(architecture: 'arm64');
      final physical = composePhysicalFeatures(runtime);
      expect(physical.flutterRuntime.host.architecture, 'arm64');
      expect(
        XcrossCli.buildRunner(runtime, configTerminal: TestTerminal()).commands,
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
      final runtime = testRuntime(
        environment: const {'XCROSS_NO_UPDATE_CHECK': '1'},
      );
      final code = await XcrossCli.run(
        ['flutter', 'build', '--profile'],
        runtime,
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
  pymd: runtime.pymd,
  flutter: runtime.flutter,
  compose: runtime.compose,
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
