import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';

import 'test_log_output.dart';

void main() {
  for (final status in [199, 200, 204, 299, 300, 503]) {
    test(
      'HTTP probe drains and closes status $status without processes',
      () async {
        final client = ProbeHttpClient(status: status);
        final availability = PymdTunnelAvailability(
          localHttp: LocalHttp(MacOSHost(), createClient: () => client),
        );
        expect(await availability.isReachable(), status >= 200 && status < 300);
        expect(client.connectionTimeout, const Duration(seconds: 3));
        expect(client.uri, Uri.parse(TunnelConstants.tunneldUrl));
        expect(client.response.drained, isTrue);
        expect(client.closed, isTrue);
        expect(client.findProxy!(client.uri!), 'DIRECT');
      },
    );
  }

  for (final failure in ['connect', 'response', 'drain']) {
    test('HTTP probe closes and returns false on $failure failure', () async {
      final client = ProbeHttpClient(failure: failure);
      final availability = PymdTunnelAvailability(
        localHttp: LocalHttp(MacOSHost(), createClient: () => client),
      );
      expect(await availability.isReachable(), isFalse);
      expect(client.closed, isTrue);
    });
  }

  test('HTTP factory failure returns false', () async {
    final availability = PymdTunnelAvailability(
      localHttp: LocalHttp(
        MacOSHost(),
        createClient: () => throw StateError('factory failed'),
      ),
    );
    expect(await availability.isReachable(), isFalse);
  });

  test(
    'physical diagnostics preserve resolution, discovery and routing',
    () async {
      final processes = DiagnosticsProcesses();
      final host = MacOSHost(processes: processes);
      final client = ProbeHttpClient(body: '{}');
      final runner = ProcessRunner(
        host,
        configuration: ProcessConfiguration(
          normalizedTools: const {'pymobiledevice3': '/selected/pymd'},
          effectiveChildEnvironment: const {},
        ),
        log: testLog(),
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
      );
      final pymd = Pymd(
        runner,
        hostPolicy: DiagnosticsHostPolicy(),
        privileges: ForbiddenPrivileges(),
        console: TestDeviceConsole(),
        localHttp: LocalHttp(host, createClient: () => client),
      );
      final DeviceDiagnostics diagnostics = PymdDeviceDiagnostics(pymd);
      final DevicePreparation preparation = DevicePrepare(pymd);
      expect(preparation, isA<DevicePrepare>());
      expect(await diagnostics.resolveExecutable(), '/selected/pymd');
      expect(processes.arguments, isEmpty);
      final devices = await diagnostics.devices();
      expect(devices.single.udid, 'USB');
      expect(await diagnostics.osMajorVersion(devices.single), 18);
      expect(
        await diagnostics.osMajorVersion(
          const Device(
            name: 'Wireless',
            udid: 'WIFI',
            type: ConnectionType.wifi,
            source: DeviceSource.tunneld,
          ),
        ),
        18,
      );
      expect(processes.arguments, [
        ['usbmux', 'list'],
        ['lockdown', 'info', '--udid', 'USB'],
        ['lockdown', 'info', '--tunnel', 'WIFI'],
      ]);
      expect(processes.executables, everyElement('/selected/pymd'));
      expect(client.closed, isTrue);
      processes.versionBody = '{}';
      expect(
        await diagnostics.osMajorVersion(
          const Device(
            name: 'Wireless',
            udid: 'WIFI',
            type: ConnectionType.wifi,
            source: DeviceSource.tunneld,
          ),
        ),
        isNull,
      );
      expect(processes.arguments, hasLength(4));
      expect(processes.arguments.last, [
        'lockdown',
        'info',
        '--tunnel',
        'WIFI',
      ]);
    },
  );

  test(
    'missing diagnostic tool fails without installation or subprocesses',
    () async {
      final processes = DiagnosticsProcesses();
      final host = MacOSHost(processes: processes);
      final runner = ProcessRunner(
        host,
        log: testLog(),
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
      );
      final diagnostics = PymdDeviceDiagnostics(
        Pymd(
          runner,
          hostPolicy: DiagnosticsHostPolicy(),
          privileges: ForbiddenPrivileges(),
          console: TestDeviceConsole(),
          localHttp: LocalHttp(
            host,
            createClient: () => throw StateError('no HTTP'),
          ),
        ),
      );
      await expectLater(
        diagnostics.resolveExecutable(),
        throwsA(isA<TunnelError>()),
      );
      expect(processes.arguments, isEmpty);
    },
  );
}

final class ProbeHttpClient implements HttpClient {
  ProbeHttpClient({int status = 200, String body = '', this.failure})
    : response = ProbeHttpResponse(status, body, failure: failure);

  final String? failure;
  final ProbeHttpResponse response;
  Uri? uri;
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  String Function(Uri)? findProxy;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uri = url;
    if (failure == 'connect') throw const SocketException('fake connect');
    return ProbeHttpRequest(response, failure: failure);
  }

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected HTTP operation: ${invocation.memberName}');
}

final class ProbeHttpRequest implements HttpClientRequest {
  ProbeHttpRequest(this.response, {this.failure});
  final ProbeHttpResponse response;
  final String? failure;

  @override
  Future<HttpClientResponse> close() async {
    if (failure == 'response') throw StateError('fake response');
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected request operation');
}

final class ProbeHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  ProbeHttpResponse(this.statusCode, this.body, {this.failure});
  @override
  final int statusCode;
  final String body;
  final String? failure;
  bool drained = false;

  @override
  Future<E> drain<E>([E? futureValue]) async {
    drained = true;
    if (failure == 'drain') throw StateError('fake drain');
    return futureValue as E;
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected response operation');
}

final class DiagnosticsProcesses implements HostProcessInterface {
  final arguments = <List<String>>[];
  final executables = <String>[];
  String versionBody = '{"ProductVersion":"18.2"}';

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
    executables.add(executable);
    this.arguments.add(List.of(arguments));
    final body = arguments.first == 'usbmux'
        ? '[{"DeviceName":"Phone","UniqueDeviceID":"USB","ConnectionType":"USB"}]'
        : versionBody;
    return DiagnosticsChild(body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected physical process operation');
}

final class DiagnosticsChild implements Process {
  DiagnosticsChild(this.body) {
    input.stream.listen((_) {});
  }
  final String body;
  final input = StreamController<List<int>>();
  late final IOSink sink = IOSink(input.sink);
  @override
  Future<int> get exitCode => Future.value(0);
  @override
  int get pid => 123;
  @override
  IOSink get stdin => sink;
  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(body));
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      throw StateError('no physical signals');
}

final class ForbiddenPrivileges implements HostPrivilegesInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no diagnostic elevation');
}

final class DiagnosticsHostPolicy implements DeviceHostPolicy {
  @override
  String get installCommand => 'manual install';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no installation or daemon services');
}
