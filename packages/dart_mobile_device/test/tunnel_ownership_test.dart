import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:dart_mobile_device/src/host/shared/tunnel/tunnel_process_controller.dart';
import 'package:test/test.dart';

import 'test_log_output.dart';

void main() {
  test('PID files never authorize stale daemon termination', () async {
    final directory = Directory.systemTemp.createTempSync('tunnel_ownership_');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/xcross-tunneld.pid').writeAsStringSync('123');
    final processes = Processes();
    final runner = ProcessRunner(
      stdinStream: const Stream.empty(),
      stdoutSink: testSink(),
      stderrSink: testSink(),
      MacOSHost(temporaryDirectory: directory.path, processes: processes),
      log: testLog(),
    );
    final daemon = TunnelDaemon(
      Pymd(
        console: TestDeviceConsole(),
        localHttp: testLocalHttp(),
        runner,
        privileges: PosixPrivileges(runner),
        hostPolicy: MacOSDeviceHost(runner),
      ),
    );
    expect(await daemon.restartStale(), isFalse);
    daemon.stop();
    await Future<void>.delayed(Duration.zero);
    expect(processes.starts, 0);
    expect(processes.terminated, isEmpty);
  });

  test(
    'concurrent startup tracks one child and shutdown only receives that child',
    () async {
      final directory = Directory.systemTemp.createTempSync('tunnel_child_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final processes = Processes();
      final runner = ProcessRunner(
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
        MacOSHost(temporaryDirectory: directory.path, processes: processes),
        log: testLog(),
      );
      final controller = TunnelProcessController(runner);
      await controller.stop();
      expect(processes.terminated, isEmpty);
      final first = controller.start(
        ['owned-tool', 'tunneld'],
        logPath: '${directory.path}/log',
        environment: const {},
      );
      final second = controller.start(
        ['owned-tool', 'tunneld'],
        logPath: '${directory.path}/log',
        environment: const {},
      );
      await Future.wait([first, second]);
      expect(processes.starts, 1);
      expect(controller.ownsProcess, isTrue);
      await Future.wait([controller.stop(), controller.stop()]);
      expect(processes.terminated, [same(processes.child)]);
      expect(controller.ownsProcess, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
  );
}

final class Processes implements HostProcessInterface {
  final child = Child();
  int starts = 0;
  final terminated = <Process>[];

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    starts++;
    await Future<void>.delayed(Duration.zero);
    return child;
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {
    terminated.add(process);
    child.exited.complete(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected host operation');
}

final class Child implements Process {
  final exited = Completer<int>();
  final input = StreamController<List<int>>();
  late final IOSink sink = IOSink(input.sink);

  Child() {
    input.stream.listen((_) {});
  }

  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 123;
  @override
  IOSink get stdin => sink;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      throw StateError('no unverified signal');
}
