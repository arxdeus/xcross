import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';

/// A host whose processes are scripted Swift and git tools.
@internal
final class FixtureSwiftHost implements PlatformHostInterface {
  FixtureSwiftHost(this.base, this.processes);
  final PlatformHostInterface base;
  @override
  final FixtureSwiftProcesses processes;
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

/// Answers `swiftc -print-target-info`, `swift build` and the git commands
/// the OpenAppleMacros source fallback runs.
@internal
final class FixtureSwiftProcesses implements HostProcessInterface {
  FixtureSwiftProcesses(this.paths, {required this.resourcePath});
  final HostPathsInterface paths;
  final String resourcePath;
  String compilerVersion = 'Swift version 6.4';
  int buildExitCode = 0;
  final calls = <List<String>>[];
  int builds = 0;
  int fetches = 0;

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
    if (paths.context.basenameWithoutExtension(executable) == 'git') {
      if (arguments.first == 'checkout') {
        fetches++;
        File(paths.context.join(workingDirectory!, 'Package.swift'))
          ..createSync(recursive: true)
          ..writeAsStringSync('// swift-tools-version: 6.1');
      }
      return FixtureChild();
    }
    final scratch = _value(arguments, '--scratch-path');
    final bin = paths.context.join(scratch, 'release');
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
  }) async => name;
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

  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(_stdout));
  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(_stderr));
  @override
  IOSink get stdin => IOSink(const FixtureDiscardingConsumer());
  @override
  Future<int> get exitCode => Future.value(_exitCode);
  @override
  int get pid => 0;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

@internal
final class FixtureDiscardingConsumer implements StreamConsumer<List<int>> {
  const FixtureDiscardingConsumer();

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}
}
