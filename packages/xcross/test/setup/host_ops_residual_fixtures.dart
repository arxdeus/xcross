import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:cli_kit/shared/process/tool_lookup.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../host_operations_fixtures.dart';

@internal
final class ResidualHost implements LinuxHostInterface {
  const ResidualHost({
    required this.base,
    required this.fileSystem,
    required this.paths,
    required this.processes,
  });

  final LinuxHostInterface base;
  @override
  final HostFileSystemInterface fileSystem;
  @override
  final HostPathsInterface paths;
  @override
  final HostProcessInterface processes;
  @override
  String get name => base.name;
  @override
  String get architecture => base.architecture;
  @override
  HostEnvironmentInterface get environment => base.environment;
}

@internal
final class ResidualPaths implements HostPathsInterface {
  ResidualPaths(this.root);
  @override
  String toolNameKey(String name) => name.trim();

  final String root;
  @override
  final context = p.Context(style: p.Style.posix);
  @override
  String get cacheRoot => context.join(root, 'cache');
  @override
  String get configRoot => context.join(root, 'config');
  @override
  String get temporaryRoot => context.join(root, 'tmp');
  @override
  String ioPath(String path) => path;
  @override
  String executableName(String name, {String extension = '.exe'}) => name;
  @override
  String pathKey(String path) => context.normalize(path);
}

@internal
final class ResidualFileSystem implements HostFileSystemInterface {
  ResidualFileSystem(this.logicalRoot, this.backingRoot);

  final String logicalRoot;
  final Directory backingRoot;
  final lookups = <String>[];
  final paths = p.Context(style: p.Style.posix);

  String physical(String path) {
    lookups.add(path);
    if (paths.equals(path, backingRoot.path) ||
        paths.isWithin(backingRoot.path, path)) {
      return path;
    }
    if (!paths.equals(path, logicalRoot) &&
        !paths.isWithin(logicalRoot, path)) {
      throw StateError('outside selected namespace: $path');
    }
    return paths.join(
      backingRoot.path,
      paths.relative(path, from: logicalRoot),
    );
  }

  @override
  File file(String path) => File(physical(path));
  @override
  Directory directory(String path) => Directory(physical(path));
  @override
  Link link(String path) => Link(physical(path));
  @override
  void makeExecutable(String path) => physical(path);
  @override
  void setPermissions(String path, int mode) => physical(path);
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      link(destination).create(target);
}

@internal
final class ResidualProcesses implements HostProcessInterface {
  ResidualProcesses(this.onStart);
  @override
  ProcessExitDiagnostic describeExit(int exitCode) {
    if (exitCode < 0 || exitCode > 255) {
      throw StateError('Unexpected fixture exit: $exitCode');
    }
    return const ProcessExitDiagnostic(crashed: false, description: null);
  }

  final Future<Process> Function(String, List<String>, String?) onStart;
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => onStart(executable, arguments, workingDirectory);

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => null;

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async => process.kill();
}

@internal
final class ResidualChild implements Process {
  ResidualChild({this.code = 0, this.output = '', this.errors = ''});

  final int code;
  final String output;
  final String errors;
  @override
  final IOSink stdin = fixtureSink();
  Future<void> close() => stdin.close();
  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(output));
  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(errors));
  @override
  Future<int> get exitCode async => code;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

@internal
final class ResidualLookup
    implements ProcessToolLookupInterface<PlatformHostInterface> {
  ResidualLookup(this.host, this.find) : base = ProcessToolLookup(host);

  final ProcessToolLookup<PlatformHostInterface> base;
  final Future<String?> Function(String, List<String>) find;
  @override
  final PlatformHostInterface host;
  @override
  ProcessConfiguration? get configuration => null;
  @override
  Map<String, String> get effectiveEnvironment => base.effectiveEnvironment;
  @override
  String resolveExecutable(String executable) =>
      base.resolveExecutable(executable);
  @override
  String hostExecutableName(String name, {String extension = '.exe'}) =>
      base.hostExecutableName(name, extension: extension);
  @override
  String? environmentValue(Map<String, String> environment, String name) =>
      base.environmentValue(environment, name);
  @override
  bool isSwiftlyProxy(String path) => base.isSwiftlyProxy(path);
  @override
  Future<String?> which(
    String name, {
    Map<String, String>? environment,
    bool Function(String)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) => find(name, extraDirectories.toList());
  @override
  Future<List<String>> whichAll(
    String name, {
    Map<String, String>? environment,
    bool Function(String)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) async {
    final result = await which(name, extraDirectories: extraDirectories);
    return result == null ? [] : [result];
  }

  @override
  Future<String> locateTool(
    String name, {
    Iterable<String> extraDirectories = const [],
  }) async =>
      await which(name, extraDirectories: extraDirectories) ??
      (throw StateError('missing fixture tool $name'));
}

@internal
ProcessRunner residualRunner(
  PlatformHostInterface host, {
  Future<String?> Function(String, List<String>)? lookup,
}) => ProcessRunner(
  host,
  log: fixtureLog(),
  stdinStream: const Stream.empty(),
  stdoutSink: fixtureSink(),
  stderrSink: fixtureSink(),
  toolLookup: lookup == null ? null : ResidualLookup(host, lookup),
);

@internal
LinuxHostInterface residualProcessHost(
  LinuxHostInterface base,
  Future<Process> Function(String, List<String>, String?) start,
) {
  return ResidualHost(
    base: base,
    fileSystem: base.fileSystem,
    paths: base.paths,
    processes: ResidualProcesses(start),
  );
}
