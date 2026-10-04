import 'dart:convert';
import 'dart:io';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';

@internal
Log fixtureLog() => Log(output: FixtureLogOutput());

@internal
final class FixtureLogOutput implements LogOutput {
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) => print(message);
  @override
  void stderr(String message) => print(message);
  @override
  void write(String message) => print(message);
}

@internal
final class FixturePrivileges implements HostPrivilegesInterface {
  @override
  Future<void> ensureElevated({
    String? manualHint,
    String? deniedMessage,
  }) async => throw StateError('unexpected fixture elevation');
  @override
  Future<void> cacheCredentials({String? manualHint}) async =>
      throw StateError('unexpected fixture credentials');
  @override
  Future<String?> resolve() async => null;
}

@internal
FixtureIOSink fixtureSink() => FixtureIOSink();

@internal
final class FixtureIOSink implements IOSink {
  final buffer = StringBuffer();
  @override
  Encoding encoding = utf8;
  @override
  void add(List<int> data) => buffer.write(encoding.decode(data));
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  void write(Object? object) => buffer.write(object);
  @override
  void writeln([Object? object = '']) => buffer.writeln(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      buffer.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (error is Exception) {
      throw error;
    }
    if (error is Error) {
      throw error;
    }
    throw StateError('$error');
  }

  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
}

@internal
ProcessRunner<T> fixtureRunner<T extends PlatformHostInterface>(
  T host, {
  required Log log,
  Stream<List<int>> stdinStream = const Stream.empty(),
  ProcessConfiguration? configuration,
}) => ProcessRunner(
  host,
  log: log,
  stdinStream: stdinStream,
  stdoutSink: fixtureSink(),
  stderrSink: fixtureSink(),
  configuration: configuration,
);

@internal
final class FixtureMappedFileSystem implements HostFileSystemInterface {
  FixtureMappedFileSystem(this.root);
  final Directory root;
  final touched = <String>[];
  String physical(String path) => path.startsWith('${root.path}/')
      ? path
      : '${root.path}/${path.replaceFirst(RegExp('^/+'), '')}';
  @override
  File file(String path) {
    touched.add(path);
    return File(physical(path));
  }

  @override
  Directory directory(String path) {
    touched.add(path);
    return Directory(physical(path));
  }

  @override
  Link link(String path) {
    touched.add(path);
    return Link(physical(path));
  }

  @override
  void makeExecutable(String path) {
    touched.add(path);
  }

  @override
  void setPermissions(String path, int mode) {
    touched.add(path);
  }

  @override
  Future<void> createArchiveLink(String destination, String target) =>
      link(destination).create(target);
}
