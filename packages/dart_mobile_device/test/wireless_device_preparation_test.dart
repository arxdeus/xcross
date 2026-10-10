import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/shared/http/local_http.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:dart_mobile_device/shared/host/device_host_policy.dart';
import 'package:dart_mobile_device/target/iphone/device/device_prepare.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

import 'device_roles_test.dart';
import 'test_log_output.dart';

void main() {
  test(
    'USB preparation delegates denial to selected policy before other effects',
    () async {
      final processes = WirelessProcesses();
      final host = MacOSHost(processes: processes);
      final privileges = DeniedPreparationPrivileges();
      final runner = ProcessRunner(
        host,
        configuration: ProcessConfiguration(
          normalizedTools: const {'pymobiledevice3': '/fixture/pymd'},
          effectiveChildEnvironment: const {},
        ),
        log: testLog(),
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
      );
      final preparation = DevicePrepare(
        Pymd(
          runner,
          hostPolicy: WirelessHostPolicy(),
          privileges: privileges,
          console: TestDeviceConsole(),
          localHttp: LocalHttp(
            host,
            createClient: () => throw StateError('no HTTP before denial'),
          ),
        ),
      );
      await expectLater(preparation.prepare(), throwsStateError);
      expect(privileges.deniedMessage, 'selected preparation denial');
      expect(privileges.manualHint, contains('selected mounter auto-mount'));
      expect(processes.arguments, isEmpty);
    },
  );

  test(
    testOn: '!windows',

    'USB wireless bootstrap preserves pairing, wifi and DDI ordering',
    () async {
      final home = Directory.systemTemp.createTempSync(
        'wireless_usb_preparation_',
      );
      addTearDown(() => home.deleteSync(recursive: true));
      final processes = WirelessProcesses(hasUsb: true);
      final host = MacOSHost(processes: processes);
      final runner = ProcessRunner(
        host,
        configuration: ProcessConfiguration(
          normalizedTools: const {'pymobiledevice3': '/fixture/pymd'},
          effectiveChildEnvironment: const {
            'USBMUXD_SOCKET_ADDRESS': 'fixture-usbmux',
          },
        ),
        log: testLog(),
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
      );
      final preparation = DevicePrepare(
        Pymd(
          runner,
          pairingHome: home.path,
          hostPolicy: WirelessHostPolicy(),
          privileges: ForbiddenPrivileges(),
          console: TestDeviceConsole(),
          localHttp: LocalHttp(
            host,
            createClient: () => ProbeHttpClient(
              body: '{"USB":[{"address":"fd00::1","port":1234}]}',
            ),
          ),
        ),
      );
      await preparation.prepareWireless();
      expect(processes.arguments, [
        ['usbmux', 'list', '--usb'],
        ['lockdown', 'remotepairing', '--pair', '--udid', 'USB'],
        ['lockdown', 'wifi-connections', '--state', 'on', '--udid', 'USB'],
        ['mounter', 'auto-mount', '--rsd', 'fd00::1', '1234'],
      ]);
      expect(processes.cleaned, isEmpty);
    },
  );

  for (final failWait in [false, true]) {
    test(
      'wireless ${failWait ? "failure" : "connection"} cleans owned advertisement through runner',
      () async {
        final home = Directory.systemTemp.createTempSync(
          'wireless_preparation_',
        );
        addTearDown(() => home.deleteSync(recursive: true));
        final processes = WirelessProcesses();
        final fileSystem = WirelessFixtureFileSystem(failWait: failWait);
        final host = MacOSHost(processes: processes, fileSystem: fileSystem);
        final runner = ProcessRunner(
          host,
          configuration: ProcessConfiguration(
            normalizedTools: const {'pymobiledevice3': '/fixture/pymd'},
            effectiveChildEnvironment: const {
              'USBMUXD_SOCKET_ADDRESS': 'fixture-usbmux',
            },
          ),
          log: testLog(),
          stdinStream: const Stream.empty(),
          stdoutSink: testSink(),
          stderrSink: testSink(),
        );
        var requests = 0;
        final pymd = Pymd(
          runner,
          pairingHome: home.path,
          hostPolicy: WirelessHostPolicy(),
          privileges: ForbiddenPrivileges(),
          console: TestDeviceConsole(),
          localHttp: LocalHttp(
            host,
            createClient: () {
              requests++;
              return ProbeHttpClient(
                body: requests <= 2
                    ? '{}'
                    : '{"WIFI":[{"address":"fd00::1","port":1234}]}',
              );
            },
          ),
        );
        final preparation = DevicePrepare(pymd);
        if (failWait) {
          await expectLater(preparation.prepareWireless(), throwsStateError);
        } else {
          await preparation.prepareWireless();
        }
        expect(processes.cleaned, [same(processes.advertisement)]);
        expect(processes.arguments.take(3), [
          ['usbmux', 'list', '--usb'],
          ['remote', 'pair-host', '--help'],
          [
            'remote',
            'pair-host',
            '--name',
            'xcross-xcross',
            '--timeout',
            '180',
          ],
        ]);
        if (failWait) {
          expect(processes.arguments, hasLength(3));
        } else {
          expect(processes.arguments.last, [
            'mounter',
            'auto-mount',
            '--rsd',
            'fd00::1',
            '1234',
          ]);
        }
        await processes.advertisement.stdin.done;
      },
    );
  }
}

@internal
final class WirelessFixtureFileSystem implements HostFileSystemInterface {
  WirelessFixtureFileSystem({required this.failWait});
  final bool failWait;
  int reads = 0;

  @override
  Directory directory(String path) {
    reads++;
    if (failWait && reads == 2) throw StateError('fake pairing read failure');
    return Directory(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected native filesystem operation');
}

@internal
final class WirelessHostPolicy implements DeviceHostPolicy {
  @override
  String get preparationDeniedMessage => 'selected preparation denial';

  @override
  String elevatedCommand(String arguments) => 'selected $arguments';

  @override
  String describeTunnelFailure(List<String> recent) => 'selected failure';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected host installation or daemon policy');
}

@internal
final class WirelessProcesses implements HostProcessInterface {
  WirelessProcesses({this.hasUsb = false});
  final bool hasUsb;
  final arguments = <List<String>>[];
  final cleaned = <Process>[];
  final advertisement = WirelessChild();

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
    expect(executable, '/fixture/pymd');
    this.arguments.add(List.of(arguments));
    if (arguments.contains('--name')) return advertisement;
    final child = WirelessChild(
      body: arguments.first == 'usbmux'
          ? (hasUsb
                ? '[{"DeviceName":"Phone","UniqueDeviceID":"USB","ConnectionType":"USB"}]'
                : '[]')
          : '',
    );
    child.exited.complete(0);
    return child;
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {
    cleaned.add(process);
    expect(process, same(advertisement));
    advertisement.exited.complete(0);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected native process operation');
}

@internal
final class DeniedPreparationPrivileges implements HostPrivilegesInterface {
  String? manualHint;
  String? deniedMessage;

  @override
  Future<void> ensureElevated({String? manualHint, String? deniedMessage}) {
    this.manualHint = manualHint;
    this.deniedMessage = deniedMessage;
    throw StateError('fake denied');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected privilege operation');
}

@internal
final class WirelessChild implements Process {
  WirelessChild({this.body = ''}) {
    input.stream.listen((_) {});
    addTearDown(close);
  }
  final String body;
  final exited = Completer<int>();
  final input = StreamController<List<int>>();
  late final IOSink sink = IOSink(input.sink);
  Future<void> close() async {
    await sink.close();
    await input.close();
  }

  @override
  Future<int> get exitCode => exited.future;
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
      throw StateError('cleanup must use selected runner');
}
