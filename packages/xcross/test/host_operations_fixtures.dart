import 'dart:convert';
import 'dart:io';
import 'package:cli_kit/cli_kit_shared.dart';

Log fixtureLog() => Log(output: FixtureLogOutput());

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

FixtureIOSink fixtureSink() => FixtureIOSink();

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

final class FixtureMappedFileSystem implements HostFileSystemInterface {
  FixtureMappedFileSystem(this.root);
  final Directory root;
  final touched = <String>[];
  String physical(String path) =>
      '${root.path}/${path.replaceFirst(RegExp('^/+'), '')}';
  @override
  File file(String path) {
    touched.add(path);
    return FixtureMappedFile(this, path);
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

final class FixtureMappedFile implements File {
  FixtureMappedFile(this.fileSystem, this.path);
  final FixtureMappedFileSystem fileSystem;
  @override
  final String path;
  File get delegate => File(fileSystem.physical(path));
  @override
  bool existsSync() => delegate.existsSync();
  @override
  String resolveSymbolicLinksSync() => delegate
      .resolveSymbolicLinksSync()
      .substring(fileSystem.root.path.length);
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      delegate.readAsStringSync(encoding: encoding);
  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => delegate.writeAsStringSync(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  File createSync({bool recursive = false, bool exclusive = false}) {
    delegate.createSync(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) =>
      delegate.deleteSync(recursive: recursive);
  @override
  Directory get parent => delegate.parent;
  @override
  Future<File> copy(String newPath) async {
    await delegate.copy(fileSystem.physical(newPath));
    return fileSystem.file(newPath);
  }

  @override
  Future<File> rename(String newPath) async {
    await delegate.rename(fileSystem.physical(newPath));
    return fileSystem.file(newPath);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      delegate.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
