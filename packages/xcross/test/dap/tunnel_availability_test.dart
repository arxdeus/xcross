import 'dart:async';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_paths.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:dart_mobile_device/shared/tunnel/tunnel_availability.dart';
import 'package:dds/dap.dart';
import 'package:frontend_server_kit/shared/compiler/package_uris.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/dap/dap_router.dart';
import 'package:xcross/src/shared/dap/xcross_dap.dart';

import '../device/test_log_output.dart';

void main() {
  for (final outcome in ['reachable', 'unreachable', 'timeout']) {
    test('DAP $outcome probe continues into selected child launch', () async {
      final root = Directory.systemTemp.createTempSync('dap_availability_');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/.dart_tool').createSync();
      File('${root.path}/.dart_tool/package_config.json').writeAsStringSync(
        '{"configVersion":2,"packages":[{"name":"dap_fixture","rootUri":"../","packageUri":"lib/"}]}',
      );
      final processes = AvailabilityProcesses();
      final logicalRoot = '/dap-${p.basename(root.path)}';
      final paths = PosixPaths(currentDirectory: logicalRoot);
      final fileSystem = DapFixtureFileSystem(
        logicalRoot,
        root.path,
        paths.context,
      );
      final runner = ProcessRunner(
        MacOSHost(processes: processes, fileSystem: fileSystem, paths: paths),
        log: testLog(),
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
      );
      final input = StreamController<List<int>>();
      final output = StreamController<List<int>>();
      final events = <Map<String, Object?>>[];
      final parser = DapFrameParser();
      output.stream.listen((bytes) {
        events.addAll(parser.push(bytes).map((frame) => frame.json));
      });
      final channel = ByteStreamServerChannel(input.stream, output.sink, null);
      final availability = FakeTunnelAvailability(outcome);
      final adapter = XcrossDap(
        channel,
        runner: runner,
        tunnelAvailability: availability,
        launcher: '/selected/xcross',
        packageUriLoader: PackageUriLoader(
          fileSystem: runner.host.fileSystem,
          paths: runner.host.paths.context,
        ),
      );
      adapter.args = DartLaunchRequestArguments.fromJson({
        'program': 'lib/main.dart',
        'cwd': logicalRoot,
      });
      var responded = false;
      final watch = Stopwatch()..start();
      await adapter.launchAndRespond(() => responded = true);
      watch.stop();
      await Future<void>.delayed(Duration.zero);
      expect(availability.calls, 1);
      expect(fileSystem.directories, [logicalRoot]);
      expect(
        fileSystem.files,
        contains('$logicalRoot/.dart_tool/package_config.json'),
      );
      expect(responded, isTrue);
      expect(processes.executable, '/selected/xcross');
      expect(processes.arguments, [
        'flutter',
        'run',
        '--target',
        'lib/main.dart',
      ]);
      expect(processes.environment, {'XCROSS_DAP': '1'});
      expect(processes.workingDirectory, logicalRoot);
      expect(
        adapter
            .convertUriToOrgDartlangSdk(
              paths.context.toUri('$logicalRoot/lib/main.dart'),
            )
            .toString(),
        'package:dap_fixture/main.dart',
      );
      expect(Directory(logicalRoot).existsSync(), isFalse);
      final warnings = events.where((event) => event['event'] == 'output');
      if (outcome == 'reachable') {
        expect(warnings, isEmpty);
      } else {
        expect(warnings, hasLength(2));
        final bodies = warnings
            .map((event) => event['body']! as Map<String, Object?>)
            .toList();
        expect(bodies.map((body) => body['category']), everyElement('stderr'));
        final text = bodies.map((body) => body['output']).join();
        expect(text, contains('falling back to the userspace tunnel'));
        expect(text, contains('run `xcross tunnel` once'));
      }
      if (outcome == 'timeout') {
        expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 5)));
      }
      processes.child.exited.complete(0);
      await adapter.disconnectImpl();
      await input.close();
      await processes.child.stdin.close();
      expect(processes.kills, 0);
    });
  }
}

@internal
final class FakeTunnelAvailability implements TunnelAvailability {
  FakeTunnelAvailability(this.outcome);
  final String outcome;
  int calls = 0;

  @override
  Future<bool> isReachable() {
    calls++;
    return outcome == 'timeout'
        ? Completer<bool>().future
        : Future.value(outcome == 'reachable');
  }
}

@internal
final class AvailabilityProcesses implements HostProcessInterface {
  final child = AvailabilityChild();
  String? executable;
  List<String>? arguments;
  Map<String, String>? environment;
  String? workingDirectory;
  int kills = 0;

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
    this.executable = executable;
    this.arguments = List.of(arguments);
    this.environment = environment;
    this.workingDirectory = workingDirectory;
    return child;
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) {
    kills++;
    throw StateError('no native termination');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected host operation');
}

@internal
final class AvailabilityChild implements Process {
  AvailabilityChild() {
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
      throw StateError('no native signals');
}

@internal
final class DapFixtureFileSystem implements HostFileSystemInterface {
  DapFixtureFileSystem(this.logicalRoot, this.backingRoot, this.paths);
  final String logicalRoot;
  final String backingRoot;
  final p.Context paths;
  String map(String path) {
    if (path == logicalRoot) return backingRoot;
    if (!paths.isWithin(logicalRoot, path)) {
      throw StateError('outside selected DAP namespace: $path');
    }
    return paths.join(backingRoot, paths.relative(path, from: logicalRoot));
  }

  final directories = <String>[];
  final files = <String>[];

  @override
  File file(String path) {
    files.add(path);
    return File(map(path));
  }

  @override
  Directory directory(String path) {
    directories.add(path);
    return Directory(map(path));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected filesystem operation');
}
