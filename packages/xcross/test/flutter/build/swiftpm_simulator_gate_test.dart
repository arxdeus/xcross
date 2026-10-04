import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart' show SimulatorTarget;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_mode.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

import 'support/checkout_test_context.dart';
import 'swiftpm_test_context.dart';

void main() {
  late Directory root;
  setUp(() {
    final temporary = Directory.systemTemp.createTempSync('gate-test-');
    root = Directory(temporary.resolveSymbolicLinksSync());
  });
  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('bounded gate processes', () {
    test('captures complete output and exit', () async {
      final context = CheckoutTestContext(
        root,
        (_) => CheckoutTestProcess(
          output: utf8.encode('output'),
          error: utf8.encode('error'),
          code: 7,
        ),
      );
      addTearDown(context.output.close);
      final result = await SwiftPmGateExecution(runner: context.runner)
          .runGateProcess(
            'fixture',
            const [],
            timeout: const Duration(seconds: 1),
          );
      expect(result.exitCode, 7);
      expect(result.stdout, 'output');
      expect(result.stderr, 'error');
    });

    for (final behavior in [
      'terminated',
      'live exit',
      'live pipes',
      'kill throws',
      'exit fails',
      'output fails',
      'cancel throws',
      'sync cancel throws',
      'setup throws',
      'drain terminated',
    ]) {
      test('timeout with $behavior preserves completion status', () async {
        final process = ControlledGateTestProcess(behavior);
        if (behavior == 'live pipes' || behavior == 'drain terminated') {
          process.exited.complete(0);
        }
        if (behavior == 'exit fails') {
          scheduleMicrotask(
            () => process.exited.completeError(StateError('exit failed')),
          );
        }
        if (behavior == 'output fails') {
          scheduleMicrotask(
            () => process.output.addError(StateError('pipe failed')),
          );
        }
        final context = CheckoutTestContext(root, (_) => process);
        addTearDown(context.output.close);
        addTearDown(process.dispose);
        final watch = Stopwatch()..start();
        await expectLater(
          SwiftPmGateExecution(runner: context.runner).runGateProcess(
            'fixture',
            const [],
            timeout: const Duration(milliseconds: 10),
          ),
          throwsA(
            (behavior == 'terminated' || behavior == 'drain terminated')
                ? isA<TimeoutException>()
                : isA<SwiftPmGateLiveProcessException>(),
          ),
        );
        expect(process.killed, isTrue);
        expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
      });
    }
  });

  group('selected Windows gate', () {
    for (final simulator in [false, true]) {
      for (final mode in SwiftPmGateMode.values) {
        test(
          '${simulator ? 'simulator' : 'device'} ${mode.name} probe',
          () async {
            final runtime = testWindowsSwiftPmRuntime(
              currentDirectory: root.path,
              environment: {
                'USERPROFILE': root.path,
                'LOCALAPPDATA': root.path,
                'TEMP': root.path,
                'TMP': root.path,
              },
              targetPolicy: simulator
                  ? (host) => SimulatorFlutterTarget(SimulatorTarget(host))
                  : null,
            );
            final executor = RecordingGateTestProcess(runtime.runner.host);
            final gate = WindowsSwiftPmGatePlatform(
              execution: executor,
              fileSystem: runtime.artifactFileSystem,
              sdkRepository: runtime.sdkRepository,
              toolchain: runtime.toolchain,
              processPolicy: runtime.processPolicy,
              buildPlan: runtime.buildPlan,
              targetPolicy: runtime.targetPolicy,
              log: runtime.runner.log,
            );
            final sdk = createGateTestSdk(root);
            expect(runtime.sdkRepository.isValidBundle(sdk), isTrue);
            final identity = createGateTestToolchain(root);
            expect(
              await gate.probe(
                mode: mode,
                root: root.path,
                toolchainIdentity: identity,
                sdkIdentity: jsonEncode({
                  'path': sdk,
                  'metadata': <String, Object>{},
                }),
              ),
              isTrue,
            );
            final triple =
                runtime.targetPolicy.target.buildPlatform.swiftSdkTriple;
            expect(executor.swiftArguments, isNotEmpty);
            for (final args in executor.swiftArguments) {
              expect(args[args.indexOf('--swift-sdk') + 1], triple);
            }
            expect(
              executor.manifests.every(
                (value) => value.contains('import PackageDescription'),
              ),
              isTrue,
            );
            expect(executor.plists, isNotEmpty);
            expect(
              executor.fixtureSliceCounts.every((count) => count == 1),
              isTrue,
            );
            final sdkName = simulator ? 'iPhoneSimulator.sdk' : 'iPhoneOS.sdk';
            for (final args in executor.swiftArguments.where(
              (args) => args.contains('-sdk'),
            )) {
              expect(args.any((arg) => arg.endsWith(sdkName)), isTrue);
            }
            for (final plist in executor.plists) {
              expect(plist.contains('ios-arm64-simulator'), simulator);
              expect(plist.contains('<string>simulator</string>'), simulator);
            }
            expect(
              Directory(p.join(root.path, '.probe-${mode.name}')).existsSync(),
              isFalse,
            );
          },
        );
      }
    }

    for (final diagnosticFailure in [false, true]) {
      test(
        'uncertain process retains probe with diagnostics failure=$diagnosticFailure',
        () async {
          final runtime = testWindowsSwiftPmRuntime(
            currentDirectory: root.path,
            environment: {
              'USERPROFILE': root.path,
              'LOCALAPPDATA': root.path,
              'TEMP': root.path,
              'TMP': root.path,
            },
          );
          final sink = IOSink(CheckoutInputConsumer());
          addTearDown(sink.close);
          final runner = ProcessRunner(
            runtime.runner.host,
            log: Log(output: GateTestLogOutput(fail: diagnosticFailure)),
            stdinStream: const Stream<List<int>>.empty(),
            stdoutSink: sink,
            stderrSink: sink,
          );
          final processPolicy = SwiftPmProcessPolicy(
            host: runtime.runner.host,
            hostPolicy: runtime.hostPolicy,
            runner: runner,
            tools: runtime.tools,
          );
          final buildPlan = SwiftPmBuildPlan(
            filesystem: runtime.buildPlan.filesystem,
            hostPolicy: runtime.hostPolicy,
            runner: runner,
            previewCompiler: runtime.buildPlan.previewCompiler,
          );
          final executor = RecordingGateTestProcess(
            runtime.runner.host,
            uncertain: true,
          );
          final gate = WindowsSwiftPmGatePlatform(
            execution: executor,
            fileSystem: runtime.artifactFileSystem,
            sdkRepository: runtime.sdkRepository,
            toolchain: runtime.toolchain,
            processPolicy: processPolicy,
            buildPlan: buildPlan,
            targetPolicy: runtime.targetPolicy,
            log: runner.log,
          );
          final future = gate.probe(
            mode: SwiftPmGateMode.packageLocalArtifact,
            root: root.path,
            toolchainIdentity: createGateTestToolchain(root),
            sdkIdentity: jsonEncode({
              'path': createGateTestSdk(root),
              'metadata': <String, Object>{},
            }),
          );
          if (diagnosticFailure) {
            await expectLater(future, throwsStateError);
          } else {
            expect(await future, isFalse);
          }
          final parent = Directory(
            p.join(root.path, '.probe-packageLocalArtifact'),
          );
          expect(parent.existsSync(), isTrue);
          final retained = parent.listSync().whereType<Directory>().single;
          expect(
            File(
              p.join(retained.path, 'package', 'Package.swift'),
            ).existsSync(),
            isTrue,
          );
          expect(
            Directory(
              p.join(retained.path, 'GateFixture.xcframework'),
            ).existsSync(),
            isTrue,
          );
        },
      );
    }
  });
}

String createGateTestSdk(Directory root) {
  final sdk = p.join(root.path, 'sdk');
  for (final name in ['info.json', 'swift-sdk.json', 'toolset.json']) {
    final file = File(p.join(sdk, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{}');
  }
  for (final platform in ['iPhoneOS', 'iPhoneSimulator']) {
    final file = File(
      p.join(
        sdk,
        'Developer',
        'Platforms',
        '$platform.platform',
        'Developer',
        'SDKs',
        '$platform.sdk',
        'System',
        'Library',
        'Frameworks',
        'fixture',
      ),
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('fixture');
  }
  for (final relative in [
    'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos/layouts-arm64.yaml',
    'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphonesimulator/layouts-arm64.yaml',
    'Developer/Runtimes/XcodeDefault.xctoolchain/usr/bin/layouts-arm64.yaml',
  ]) {
    final file = File(p.join(sdk, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('fixture');
  }
  return sdk;
}

String createGateTestToolchain(Directory root) {
  final identity = <String, Object>{};
  for (final name in [
    'swift-package',
    'swift-build',
    'swiftc',
    'clang',
    'clang++',
    'ld64.lld',
    'librarian',
  ]) {
    final file = File(p.join(root.path, 'tools', name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('fixture');
    final stat = file.statSync();
    identity[name] = {
      'path': file.resolveSymbolicLinksSync(),
      'size': stat.size,
      'modified': stat.modified.microsecondsSinceEpoch,
      'changed': stat.changed.microsecondsSinceEpoch,
      'digest': sha256.convert(file.readAsBytesSync()).toString(),
      if (name.startsWith('swift')) 'version': 'fixture version',
    };
  }
  return jsonEncode(identity);
}

final class RecordingGateTestProcess implements SwiftPmGateProcess {
  RecordingGateTestProcess(this.host, {this.uncertain = false});
  @override
  final WindowsHost host;
  final bool uncertain;
  final List<List<String>> swiftArguments = [];
  final List<String> manifests = [];
  final List<String> plists = [];
  final List<int> fixtureSliceCounts = [];
  @override
  Future<ProcessResult> runGateProcess(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  }) async {
    if (arguments.contains('--version')) {
      return ProcessResult(42, 0, 'fixture version', '');
    }
    if (executable == 'cmd.exe') {
      await Link(
        arguments[3].replaceAll(r'\', '/'),
      ).create(arguments[4].replaceAll(r'\', '/'));
      return ProcessResult(42, 0, '', '');
    }
    swiftArguments.add(List.unmodifiable(arguments));
    final package = arguments[arguments.indexOf('--package-path') + 1];
    final probe = p.dirname(package);
    manifests.add(File(p.join(package, 'Package.swift')).readAsStringSync());
    plists.add(
      File(
        p.join(probe, 'GateFixture.xcframework', 'Info.plist'),
      ).readAsStringSync(),
    );
    fixtureSliceCounts.add(
      Directory(
        p.join(probe, 'GateFixture.xcframework'),
      ).listSync().whereType<Directory>().where((slice) {
        expect(
          File(
            p.join(slice.path, 'GateFixture.framework', 'GateFixture'),
          ).existsSync(),
          isTrue,
        );
        return true;
      }).length,
    );
    if (uncertain) {
      throw SwiftPmGateLiveProcessException(
        executable: executable,
        processId: 42,
        cause: TimeoutException('fixture'),
        cleanupError: StateError('still live'),
      );
    }
    if (p.basename(executable) == 'swift-package' &&
        !Directory(p.join(package, 'artifacts')).existsSync()) {
      final scratch = arguments[arguments.indexOf('--scratch-path') + 1];
      final artifact = Directory(
        p.join(scratch, 'artifacts', 'GateFixture.xcframework'),
      );
      if (!artifact.existsSync()) artifact.createSync(recursive: true);
    }
    return ProcessResult(42, 0, '', '');
  }
}

final class ControlledGateTestProcess implements Process {
  ControlledGateTestProcess(this.behavior)
    : output = StreamController<List<int>>(
        onCancel: () {
          if (behavior == 'cancel throws') {
            throw StateError('output cancel failed');
          }
        },
      ),
      error = StreamController<List<int>>(
        onCancel: () {
          if (behavior == 'cancel throws') {
            throw StateError('error cancel failed');
          }
        },
      );
  final String behavior;
  final Completer<int> exited = Completer<int>();
  final StreamController<List<int>> output;
  final StreamController<List<int>> error;
  bool killed = false;
  @override
  final IOSink stdin = IOSink(CheckoutInputConsumer());
  @override
  Stream<List<int>> get stdout {
    if (behavior == 'setup throws') throw StateError('output setup failed');
    if (behavior == 'sync cancel throws') {
      return GateThrowingCancelStream(output.stream);
    }
    return output.stream;
  }

  @override
  Stream<List<int>> get stderr => error.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 42;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (behavior == 'kill throws') throw StateError('kill failed');
    if (behavior == 'terminated' || behavior == 'drain terminated') {
      if (!exited.isCompleted) exited.complete(-1);
      unawaited(output.close());
      unawaited(error.close());
    }
    return true;
  }

  Future<void> dispose() async {
    if (behavior == 'setup throws') {
      unawaited(output.stream.drain<void>());
      unawaited(error.stream.drain<void>());
    }
    if (!exited.isCompleted) exited.complete(-1);
    await output.close();
    await error.close();
    await stdin.close();
  }
}

final class GateTestLogOutput implements LogOutput {
  GateTestLogOutput({required this.fail});
  final bool fail;
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) {}
  @override
  void stderr(String message) {
    if (fail) throw StateError('diagnostic failed');
  }

  @override
  void write(String message) {}
}

final class GateThrowingCancelStream extends Stream<List<int>> {
  GateThrowingCancelStream(this.source);
  final Stream<List<int>> source;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => GateThrowingCancelSubscription(
    source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
  );
}

final class GateThrowingCancelSubscription
    implements StreamSubscription<List<int>> {
  GateThrowingCancelSubscription(this.source);
  final StreamSubscription<List<int>> source;
  @override
  Future<void> cancel() {
    unawaited(source.cancel());
    throw StateError('synchronous cancellation failed');
  }

  @override
  void onData(void Function(List<int>)? handleData) =>
      source.onData(handleData);
  @override
  void onError(Function? handleError) => source.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => source.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => source.pause(resumeSignal);
  @override
  void resume() => source.resume();
  @override
  bool get isPaused => source.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => source.asFuture<E>(futureValue);
}
