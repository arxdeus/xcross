import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';

@internal
final class FixtureLogOutput implements LogOutput {
  final messages = <String>[];
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) => messages.add(message);
  @override
  void stderr(String message) => messages.add(message);
  @override
  void write(String message) => messages.add(message);
}

@internal
final class FixtureHost implements PlatformHostInterface {
  FixtureHost(this.base, this.processes);
  final PlatformHostInterface base;
  @override
  final HostProcessInterface processes;
  @override
  String get name => base.name;
  @override
  String get architecture => base.architecture;
  @override
  HostPathsInterface get paths => base.paths;
  @override
  HostEnvironmentInterface get environment => base.environment;
  @override
  HostFileSystemInterface get fileSystem => base.fileSystem;
}

@internal
final class FixtureSwiftProcesses implements HostProcessInterface {
  FixtureSwiftProcesses(this.paths, {required this.resourcePath});
  final HostPathsInterface paths;
  final String resourcePath;
  String compilerVersion = 'Swift version 6.3';
  int buildExitCode = 0;
  final calls = <List<String>>[];
  int builds = 0;

  @override
  ProcessExitDiagnostic describeExit(int exitCode) =>
      const ProcessExitDiagnostic(crashed: false, description: null);

  String _value(List<String> arguments, String flag) =>
      arguments[arguments.indexOf(flag) + 1];

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
    calls.add([executable, ...arguments]);
    if (arguments.contains('-print-target-info')) {
      return FixtureChild(
        stdout: jsonEncode({
          'compilerVersion': compilerVersion,
          'paths': {'runtimeResourcePath': resourcePath},
        }),
      );
    }
    final scratch = _value(arguments, '--scratch-path');
    final bin = paths.context.join(scratch, 'debug');
    if (arguments.contains('--show-bin-path')) {
      return FixtureChild(stdout: '$bin\n');
    }
    if (buildExitCode != 0) {
      return FixtureChild(stderr: 'build failed', exitCode: buildExitCode);
    }
    final manifest = File(
      paths.context.join(_value(arguments, '--package-path'), 'Package.swift'),
    );
    if (!manifest.existsSync()) {
      return FixtureChild(stderr: 'missing manifest', exitCode: 1);
    }
    builds++;
    File(paths.context.join(bin, paths.executableName('OpenAppleMacrosServer')))
      ..createSync(recursive: true)
      ..writeAsStringSync('server-$builds');
    return FixtureChild();
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {}

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => null;
}

@internal
final class FixtureChild implements Process {
  FixtureChild({String stdout = '', String stderr = '', int exitCode = 0})
    : _stdout = stdout,
      _stderr = stderr,
      _exitCode = exitCode;
  final String _stdout;
  final String _stderr;
  final int _exitCode;
  final _stdin = StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(_stdout));
  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(_stderr));
  @override
  IOSink get stdin => IOSink(_stdin.sink);
  @override
  Future<int> get exitCode => Future.value(_exitCode);
  @override
  int get pid => 0;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

@internal
ProcessRunner<FixtureHost> fixtureRunner(FixtureHost host) => ProcessRunner(
  host,
  log: Log(output: FixtureLogOutput()),
  stdinStream: const Stream<List<int>>.empty(),
  stdoutSink: IOSink(StreamController<List<int>>.broadcast().sink),
  stderrSink: IOSink(StreamController<List<int>>.broadcast().sink),
);
