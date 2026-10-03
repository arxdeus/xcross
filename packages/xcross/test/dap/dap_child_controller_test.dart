import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/dap/dap_child_controller.dart';

import '../device/test_log_output.dart';

void main() {
  test(
    'quit timeout cleans one owned child through configured host lifecycle',
    () async {
      final processes = RecordingDapProcesses();
      final runner = ProcessRunner(
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
        WindowsHost(processes: processes),
        log: testLog(),
        configuration: ProcessConfiguration(
          normalizedTools: const {'taskkill': 'C:/tools/taskkill.exe'},
          effectiveChildEnvironment: const {'SESSION': 'dap'},
        ),
      );
      final child = FakeDapChild();
      final controller = DapChildController(
        cleanup: runner.killTree,
        quitTimeout: Duration.zero,
      );
      await controller.attach(child);
      await Future.wait([controller.close(), controller.close()]);
      await child.stdin.flush();
      expect(utf8.decode(child.input), 'q');
      expect(processes.cleaned, [same(child)]);
      expect(processes.environment, {'SESSION': 'dap'});
      expect(processes.tools, {'taskkill': 'C:/tools/taskkill.exe'});
      expect(child.directSignals, 0);
      await child.dispose();
    },
  );

  for (final delayed in [false, true]) {
    test(
      'close during ${delayed ? "delayed startup" : "pre-start"} reaps late owned child',
      () async {
        final child = FakeDapChild();
        final cleaned = <Process>[];
        final controller = DapChildController(
          cleanup: (process) async {
            cleaned.add(process);
            child.exit.complete(0);
          },
        );
        final started = Completer<Process>();
        final lateAttach = delayed
            ? started.future.then(controller.attach)
            : null;
        await controller.close();
        if (delayed) {
          started.complete(child);
          await expectLater(lateAttach, throwsStateError);
        } else {
          await expectLater(controller.attach(child), throwsStateError);
        }
        expect(cleaned, [same(child)]);
        expect(child.directSignals, 0);
        await child.dispose();
      },
    );
  }

  test('graceful child exit skips forced cleanup', () async {
    final child = FakeDapChild()..exit.complete(0);
    final cleaned = <Process>[];
    final controller = DapChildController(
      cleanup: (child) async => cleaned.add(child),
    );
    await controller.attach(child);
    await controller.close();
    expect(cleaned, isEmpty);
    expect(child.directSignals, 0);
    await child.dispose();
  });
}

final class RecordingDapProcesses implements HostProcessInterface {
  final cleaned = <Process>[];
  Map<String, String>? environment;
  Map<String, String>? tools;
  @override
  Future<void> killTree(
    Process child, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {
    cleaned.add(child);
    this.environment = environment;
    tools = executableOverrides;
    (child as FakeDapChild).exit.complete(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected process creation');
}

final class FakeDapChild implements Process {
  FakeDapChild() {
    sink = IOSink(inputController.sink);
    inputController.stream.listen(input.addAll);
  }
  final inputController = StreamController<List<int>>();
  final input = <int>[];
  final exit = Completer<int>();
  late final IOSink sink;
  int directSignals = 0;
  @override
  IOSink get stdin => sink;
  @override
  Future<int> get exitCode => exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    directSignals++;
    throw StateError('ambient signalling is forbidden');
  }

  Future<void> dispose() async {
    if (!exit.isCompleted) exit.complete(0);
    await sink.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected child interaction');
}
