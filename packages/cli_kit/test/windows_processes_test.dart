import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class WindowsProcessTestPaths implements HostPathsInterface {
  WindowsProcessTestPaths(String root) : context = p.Context(current: root);

  @override
  final p.Context context;
  final List<String> ioPaths = [];

  @override
  String get configRoot => context.current;
  @override
  String get cacheRoot => context.current;
  @override
  String get temporaryRoot => context.current;
  @override
  String ioPath(String path) {
    ioPaths.add(path);
    return context.absolute(path);
  }

  @override
  String executableName(String name, {String extension = '.exe'}) =>
      '$name$extension';
  @override
  String pathKey(String path) => context.absolute(path);
}

final class WindowsProcessTestFileSystem implements HostFileSystemInterface {
  WindowsProcessTestFileSystem(this.paths);

  final HostPathsInterface paths;
  final List<String> probes = [];

  @override
  File file(String path) {
    probes.add(path);
    return File(paths.ioPath(path));
  }

  @override
  Directory directory(String path) => Directory(paths.ioPath(path));
  @override
  Link link(String path) => Link(paths.ioPath(path));
  @override
  void makeExecutable(String path) =>
      throw UnsupportedError('test permissions');
  @override
  void setPermissions(String path, int mode) =>
      throw UnsupportedError('test permissions');
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError('test links');
}

Future<Process> startWaitingChild(
  HostProcessInterface processes,
  File script,
) async {
  final process = await processes.start(Platform.resolvedExecutable, [
    script.path,
  ]);
  addTearDown(() async {
    process.kill();
    await process.exitCode;
  });
  return process;
}

void main() {
  test(
    'Windows host assembly binds the selected paths environment and filesystem',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'windows-selected-host-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final script = File(p.join(temp.path, 'wait.dart'))
        ..writeAsStringSync(
          "import 'dart:io'; Future<void> main() async { stdout.writeln(Directory.current.path); await Future<void>.delayed(const Duration(minutes: 10)); }",
        );
      for (final session in ['first', 'second']) {
        final root = Directory(p.join(temp.path, session))..createSync();
        final paths = WindowsProcessTestPaths(root.path);
        final files = WindowsProcessTestFileSystem(paths);
        final host = WindowsHost(
          paths: paths,
          fileSystem: files,
          environment: {'Path': 'selected-tools', 'PATHEXT': '.$session'},
        );
        expect(host.paths, same(paths));
        expect(host.fileSystem, same(files));
        final process = await startWaitingChild(host.processes, script);
        final cwd = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        expect(cwd, root.resolveSymbolicLinksSync());
        await host.processes.killTree(process);
        await process.exitCode;
        expect(files.probes, [
          paths.context.join('selected-tools', 'taskkill'),
          paths.context.join('selected-tools', 'taskkill.$session'),
        ]);
        expect(paths.ioPaths.first, root.path);
      }
    },
  );

  test(
    'Windows cleanup uses the supplied ports and default environment snapshot',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'windows-selected-cleanup-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final paths = WindowsProcessTestPaths(temp.path);
      final files = WindowsProcessTestFileSystem(paths);
      final environment = WindowsEnvironment({
        'Path': 'tools',
        'PATHEXT': '.selected',
        'SESSION': 'owned',
      });
      final toolDirectory = Directory(p.join(temp.path, 'tools'))..createSync();
      final taskkill = File(p.join(toolDirectory.path, 'taskkill.selected'))
        ..writeAsStringSync('fixture');
      String? invoked;
      Map<String, String>? values;
      bool? inherited;
      final processes = WindowsProcesses(
        paths: paths,
        environment: environment,
        fileSystem: files,
        runProcess:
            (
              executable,
              arguments, {
              environment,
              includeParentEnvironment = true,
            }) async {
              invoked = executable;
              values = environment;
              inherited = includeParentEnvironment;
              expect(arguments, containsAll(['/PID', '/T', '/F']));
              return ProcessResult(0, 0, '', '');
            },
      );
      final script = File(p.join(temp.path, 'wait.dart'))
        ..writeAsStringSync(
          'Future<void> main() async { await Future<void>.delayed(const Duration(minutes: 10)); }',
        );
      final process = await startWaitingChild(processes, script);
      await processes.killTree(process);
      await process.exitCode;
      expect(files.probes, [
        paths.context.join('tools', 'taskkill'),
        paths.context.join('tools', 'taskkill.selected'),
      ]);
      expect(paths.ioPath(invoked!), taskkill.path);
      expect(values, same(environment.values));
      expect(inherited, isFalse);
    },
  );
}
