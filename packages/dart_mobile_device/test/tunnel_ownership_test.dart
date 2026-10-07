import 'dart:async';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_privileges.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:dart_mobile_device/host/macos/macos_device_host.dart';
import 'package:dart_mobile_device/shared/errors/errors.dart';
import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:dart_mobile_device/src/host/shared/tunnel/tunnel_process_controller.dart';
import 'package:dart_mobile_device/src/shared/device/models/tunnel.dart';
import 'package:dart_mobile_device/src/target/iphone/device/tunnel/kernel_tunnel_transport.dart';
import 'package:dart_mobile_device/src/target/iphone/device/tunnel/tunnel_daemon.dart';
import 'package:dart_mobile_device/src/target/iphone/device/tunnel/userspace_tunnel_transport.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

import 'test_log_output.dart';

void main() {
  test('actual transports supply device-side VM bind addresses', () {
    final runner = ProcessRunner(
      MacOSHost(processes: Processes()),
      stdinStream: const Stream.empty(),
      stdoutSink: testSink(),
      stderrSink: testSink(),
      log: testLog(),
    );
    final pymd = Pymd(
      runner,
      console: TestDeviceConsole(),
      localHttp: testLocalHttp(),
      privileges: PosixPrivileges(runner),
      hostPolicy: MacOSDeviceHost(runner),
    );
    final kernel = KernelTunnelTransport(
      tunnel: const Tunnel(address: 'fe80::1234%en0', port: 123),
      debugproxyPort: 456,
      daemon: TunnelDaemon(pymd),
    );
    final userspace = UserspaceTunnelTransport(
      pymd: pymd,
      udid: 'test-device',
      sockets: RelaySockets(),
    );
    expect(kernel.vmServiceBindAddress, '::0');
    expect(userspace.vmServiceBindAddress, '0.0.0.0');
  });

  test(
    'selected fake ports reserve, probe, cache and release owned relays',
    () async {
      final processes = Processes();
      final sockets = RelaySockets();
      final transport = relayTransport(processes, sockets);
      final endpoint = await transport.devicePortEndpoint(1234);
      expect(endpoint.host, '127.0.0.1');
      expect(endpoint.port, 49123);
      expect(sockets.bindings, [0, 49123, 49123]);
      expect(sockets.probes.map((probe) => probe.closes), [1, 1]);
      expect(sockets.connections, 0);
      expect(processes.starts, 1);
      expect(processes.arguments.single, [
        'usbmux',
        'forward',
        '49123',
        '1234',
        '--host',
        '127.0.0.1',
        '--udid',
        'test-device',
      ]);
      expect(await transport.devicePortEndpoint(1234), same(endpoint));
      await transport.close();
      await transport.close();
      expect(processes.terminated, [same(processes.child)]);
    },
  );

  test('reservation failure propagates without starting a relay', () async {
    final processes = Processes();
    final failure = StateError('selected reservation failed');
    final transport = relayTransport(processes, RelaySockets(failure: failure));
    await expectLater(transport.debugproxyEndpoint(), throwsA(same(failure)));
    expect(processes.starts, 0);
    await transport.close();
    expect(processes.terminated, isEmpty);
  });

  test('non-socket probe errors retry before relay readiness', () async {
    final processes = Processes();
    final failure = StateError('selected probe failed');
    final sockets = RelaySockets(failure: failure, failAt: 2);
    final transport = relayTransport(processes, sockets);
    final endpoint = await transport.debugproxyEndpoint();
    expect(endpoint.port, 49123);
    expect(sockets.bindings, [0, 49123, 49123]);
    expect(sockets.probes.single.closes, 1);
    await transport.close();
    expect(processes.terminated, [same(processes.child)]);
  });

  test(
    'relay spawn failure preserves tunnel error and releases reservation',
    () async {
      final processes = Processes(
        startFailure: StateError('selected spawn failed'),
      );
      final sockets = RelaySockets();
      final transport = relayTransport(processes, sockets);
      await expectLater(
        transport.debugproxyEndpoint(),
        throwsA(
          isA<TunnelError>().having(
            (error) => error.message,
            'message',
            contains('could not start the debugproxy relay'),
          ),
        ),
      );
      expect(sockets.bindings, [0]);
      expect(sockets.probes.single.closes, 1);
      await transport.close();
      expect(processes.terminated, isEmpty);
    },
  );

  test('relay exit before readiness cleans up only the owned child', () async {
    final processes = Processes(exitImmediately: true);
    final sockets = RelaySockets();
    final transport = relayTransport(processes, sockets);
    await expectLater(
      transport.debugproxyEndpoint(),
      throwsA(
        isA<TunnelError>().having(
          (error) => error.message,
          'message',
          contains('exited before it started listening'),
        ),
      ),
    );
    expect(sockets.probes.map((probe) => probe.closes), everyElement(1));
    expect(sockets.connections, 0);
    expect(processes.terminated, [same(processes.child)]);
    await transport.close();
    expect(processes.terminated, hasLength(1));
  });

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

@internal
final class Processes implements HostProcessInterface {
  Processes({this.startFailure, this.exitImmediately = false});

  final Error? startFailure;
  final bool exitImmediately;
  final child = Child();
  int starts = 0;
  final arguments = <List<String>>[];
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
    this.arguments.add(List.of(arguments));
    await Future<void>.delayed(Duration.zero);
    if (startFailure case final Error failure) throw failure;
    if (exitImmediately) child.exited.complete(1);
    return child;
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {
    terminated.add(process);
    if (!child.exited.isCompleted) child.exited.complete(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected host operation');
}

@internal
final class Child implements Process {
  Child() {
    input.stream.listen((_) {});
  }
  final exited = Completer<int>();
  final input = StreamController<List<int>>();
  late final IOSink sink = IOSink(input.sink);

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

@internal
UserspaceTunnelTransport relayTransport(
  Processes processes,
  RelaySockets sockets,
) {
  final host = MacOSHost(processes: processes);
  final runner = ProcessRunner(
    host,
    configuration: ProcessConfiguration(
      normalizedTools: const {'pymobiledevice3': '/fixture/pymd'},
      effectiveChildEnvironment: const {},
    ),
    stdinStream: const Stream.empty(),
    stdoutSink: testSink(),
    stderrSink: testSink(),
    log: testLog(),
  );
  return UserspaceTunnelTransport(
    pymd: Pymd(
      runner,
      console: TestDeviceConsole(),
      localHttp: testLocalHttp(),
      privileges: PosixPrivileges(runner),
      hostPolicy: MacOSDeviceHost(runner),
    ),
    udid: 'test-device',
    sockets: sockets,
  );
}

@internal
final class RelaySockets implements DeviceSockets {
  RelaySockets({this.failure, this.failAt = 1});

  final Error? failure;
  final int failAt;
  final bindings = <int>[];
  final probes = <RelayProbe>[];
  int connections = 0;

  @override
  Future<ServerSocket> bindLoopback({int port = 0}) async {
    bindings.add(port);
    if (bindings.length == failAt && failure != null) throw failure!;
    if (bindings.length == 3) throw const SocketException('relay owns port');
    final probe = RelayProbe();
    probes.add(probe);
    return probe;
  }

  @override
  Future<Socket> connect(String host, int port, {Duration? timeout}) {
    connections++;
    throw StateError('must never connect to probe a relay');
  }
}

@internal
final class RelayProbe implements ServerSocket {
  int closes = 0;

  @override
  int get port => 49123;

  @override
  Future<ServerSocket> close() async {
    closes++;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected socket operation');
}
