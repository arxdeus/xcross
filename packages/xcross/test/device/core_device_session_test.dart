@TestOn('mac-os || linux')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_privileges.dart';
import 'package:cli_kit/shared/http/local_http.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:dart_mobile_device/host/macos/macos_device_host.dart';
import 'package:dart_mobile_device/host/shared/network/native_device_sockets.dart';
import 'package:dart_mobile_device/shared/console/device_console.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/vm_service_connector.dart';
import 'package:xcross/src/target/iphone/device/core_device_launch_profile.dart';
import 'package:xcross/src/target/iphone/device/core_device_launcher.dart';

import 'test_log_output.dart';

/// Drives a whole CoreDevice session (launch, debugserver attach, VM Service
/// publication, device log) against a scripted pymobiledevice3 and a real
/// Dart VM Service standing in for the app.
void main() {
  late Directory scratch;
  late String python;
  Process? app;

  setUpAll(() async {
    python = (await Process.run('which', ['python3'])).stdout.toString().trim();
  });

  setUp(() => scratch = Directory.systemTemp.createTempSync('xcross-session'));

  tearDown(() {
    app?.kill();
    app = null;
    scratch.deleteSync(recursive: true);
  });

  /// Start a Dart VM with its service on a free loopback port, as the app on
  /// the device would serve it.
  Future<int> startVmService() async {
    final script = File(p.join(scratch.path, 'app.dart'))
      ..writeAsStringSync(
        'Future<void> main() => Future<void>.delayed(const Duration(minutes: 2));',
      );
    final process = app = await Process.start(Platform.resolvedExecutable, [
      '--enable-vm-service=0',
      '--disable-service-auth-codes',
      '--no-dds',
      script.path,
    ]);
    final banner = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.contains('VM service is listening'));
    return int.parse(RegExp(r':(\d+)/').firstMatch(banner)!.group(1)!);
  }

  Future<LaunchedSession> launch(
    FlutterBuildMode mode, {
    required int vmPort,
    double exitAfterSeconds = 6,
  }) async {
    final bin = Directory(p.join(scratch.path, 'bin'))..createSync();
    final fake = Isolate.resolvePackageUriSync(
      Uri.parse('package:xcross/src/target/iphone/device/device_log.dart'),
    )!;
    final fixture = p.normalize(
      p.join(
        p.dirname(fake.toFilePath()),
        '../../../../../test/device/fixtures/fake_pymobiledevice3.py',
      ),
    );
    final wrapper = File(p.join(bin.path, 'pymobiledevice3'))
      ..writeAsStringSync('#!/bin/sh\nexec "$python" "$fixture" "\$@"\n');
    await Process.run('chmod', ['+x', wrapper.path]);
    final record = p.join(scratch.path, 'launch.json');

    final logOutput = TestLogOutput();
    final console = CapturingConsole();
    final host = MacOSHost(
      environment: {
        'PATH': '${bin.path}:/usr/bin:/bin',
        'HOME': scratch.path,
        'XCROSS_TUNNEL_MODE': 'userspace',
        'FAKE_VM_PORT': '$vmPort',
        'FAKE_RECORD': record,
        'FAKE_EXIT_AFTER': '$exitAfterSeconds',
        'USBMUXD_SOCKET_ADDRESS': '127.0.0.1:1',
      },
    );
    final runner = ProcessRunner(
      host,
      log: Log(output: logOutput),
      stdinStream: const Stream.empty(),
      stdoutSink: testSink(),
      stderrSink: testSink(),
    );
    final localHttp = LocalHttp(host, createClient: HttpClient.new);
    final launcher = CoreDeviceLauncher(
      Pymd(
        runner,
        console: console,
        localHttp: localHttp,
        privileges: PosixPrivileges(runner),
        hostPolicy: MacOSDeviceHost(runner),
      ),
      connector: LocalVmServiceConnector(localHttp),
      sockets: const NativeDeviceSockets(),
      vmOutput: VmServiceOutput(output: StringBuffer(), errors: StringBuffer()),
    );
    final session = LaunchedSession(logOutput.messages, console.lines);
    session.done = launcher.launch(
      udid: 'FAKE-UDID',
      bundleId: 'dev.example.app',
      profile: CoreDeviceLaunchProfile.flutter(
        buildMode: mode,
        arguments: const ['--route=/home'],
      ),
    );
    session.launchArgs = () =>
        (jsonDecode(File(record).readAsStringSync()) as List).cast<String>();
    return session;
  }

  test('profile publishes a usable VM Service and shows Dart output', () async {
    final session = await launch(
      FlutterBuildMode.profile,
      vmPort: await startVmService(),
    );
    final uri = await session.vmServiceUri();
    expect(uri, matches(RegExp(r'^ws://127\.0\.0\.1:\d+/ws$')));

    // A client (DevTools, an IDE) can talk JSON-RPC through the published
    // loopback port.
    final socket = await WebSocket.connect(uri);
    socket.add(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'getVM'}));
    final reply =
        jsonDecode(await socket.first as String) as Map<String, dynamic>;
    await socket.close();
    expect((reply['result'] as Map)['type'], 'VM');

    await session.done;
    final launched = session.launchArgs().last;
    expect(
      launched,
      allOf(
        contains('--enable-dart-profiling'),
        contains('--vm-service-port=12345'),
        contains('--enable-checked-mode'),
        contains('--route=/home'),
      ),
    );
    expect(session.console, ['hello from dart', 'second line']);
    expect(session.log, contains(contains('App exited')));
  }, skip: _pythonMissing());

  test('release serves no VM Service and still shows Dart output', () async {
    final session = await launch(
      FlutterBuildMode.release,
      vmPort: 1,
      exitAfterSeconds: 3,
    );
    await session.done;
    final launched = session.launchArgs().last;
    expect(launched, isNot(contains('--vm-service')));
    expect(launched, isNot(contains('--enable-checked-mode')));
    expect(launched, contains('--route=/home'));
    expect(session.log, isNot(contains(contains('vm-service: '))));
    expect(session.log, contains(contains('Streaming app output')));
    expect(session.console, ['hello from dart', 'second line']);
  }, skip: _pythonMissing());

  test(
    'profile session ends cleanly when the app exits before its VM Service',
    () async {
      final session = await launch(
        FlutterBuildMode.profile,
        vmPort: 1,
        exitAfterSeconds: 3,
      );
      await session.done.timeout(const Duration(seconds: 30));
      expect(session.log, isNot(contains(contains('vm-service: '))));
      expect(session.log, contains(contains('App exited')));
      expect(session.console, ['hello from dart', 'second line']);
    },
    skip: _pythonMissing(),
  );
}

Object _pythonMissing() => Process.runSync('which', ['python3']).exitCode == 0
    ? false
    : 'python3 is required for the scripted pymobiledevice3';

@internal
final class LaunchedSession {
  LaunchedSession(this.log, this.console);
  final List<String> log;
  final List<String> console;
  late Future<void> done;
  late List<String> Function() launchArgs;

  Future<String> vmServiceUri() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      for (final line in log) {
        final at = line.indexOf('vm-service: ');
        if (at >= 0) return line.substring(at + 'vm-service: '.length).trim();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('no vm-service marker in: ${log.join('\n')}');
  }
}

@internal
final class CapturingConsole implements DeviceConsole {
  final lines = <String>[];
  @override
  Stream<void> get interrupts => const Stream.empty();
  @override
  bool get inputHasTerminal => false;
  @override
  bool get outputHasTerminal => false;
  @override
  bool echoMode = true;
  @override
  bool lineMode = true;
  @override
  String? readLine() => null;
  @override
  void write(String value) {}
  @override
  void writeln(String value) => lines.add(value);
  @override
  void add(List<int> bytes) {}
}
