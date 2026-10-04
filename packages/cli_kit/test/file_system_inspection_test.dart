import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'inspects mapped files, directories, missing entries and link targets',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'selected-inspection-',
      );
      addTearDown(() => root.delete(recursive: true));
      final files = InspectionFileSystem(root.path);
      await files.file('file').writeAsString('bytes');
      await files.directory('directory').create();
      await files.link('live-file').create('file');
      await files.link('live-directory').create('directory');
      await files.link('broken').create('missing');
      final mode = files.file('file').statSync().mode;

      expect(files.typeSync('file'), FileSystemEntityType.file);
      expect(files.typeSync('directory'), FileSystemEntityType.directory);
      expect(files.typeSync('missing'), FileSystemEntityType.notFound);
      expect(files.typeSync('live-file'), FileSystemEntityType.file);
      expect(files.typeSync('live-directory'), FileSystemEntityType.directory);
      expect(files.typeSync('broken'), FileSystemEntityType.notFound);
      for (final name in ['live-file', 'live-directory', 'broken']) {
        expect(
          files.typeSync(name, followLinks: false),
          FileSystemEntityType.link,
        );
      }
      expect(
        files.typeSync('file', followLinks: false),
        FileSystemEntityType.file,
      );
      expect(
        files.typeSync('directory', followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(
        files.typeSync('missing', followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(await files.file('file').readAsString(), 'bytes');
      expect(files.file('file').statSync().mode, mode);
    },
  );

  test('retains selected stat errors and skips stat for nofollow links', () {
    const failure = FileSystemException('selected permission denied', 'denied');
    final files = FailingInspectionFileSystem(failure);
    expect(() => files.typeSync('denied'), throwsA(same(failure)));
    expect(
      () => files.typeSync('denied', followLinks: false),
      throwsA(same(failure)),
    );
    expect(
      files.typeSync('link', followLinks: false),
      FileSystemEntityType.link,
    );
    expect(files.statCalls, ['denied', 'denied']);
  });
}

final class InspectionFileSystem implements HostFileSystemInterface {
  InspectionFileSystem(this.root);
  final String root;

  @override
  File file(String path) => File(p.join(root, path));
  @override
  Directory directory(String path) => Directory(p.join(root, path));
  @override
  Link link(String path) => Link(p.join(root, path));
  @override
  void makeExecutable(String path) => throw UnsupportedError('inspection only');
  @override
  void setPermissions(String path, int mode) =>
      throw UnsupportedError('inspection only');
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError('inspection only');
}

final class FailingInspectionFileSystem implements HostFileSystemInterface {
  FailingInspectionFileSystem(this.failure);
  final FileSystemException failure;
  final List<String> statCalls = [];

  @override
  File file(String path) => FailingInspectionFile(path, failure, statCalls);
  @override
  Link link(String path) => InspectionLink(path);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(invocation.memberName.toString());
}

final class FailingInspectionFile implements File {
  FailingInspectionFile(this.path, this.failure, this.statCalls);
  @override
  final String path;
  final FileSystemException failure;
  final List<String> statCalls;

  @override
  FileStat statSync() {
    statCalls.add(path);
    throw failure;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(invocation.memberName.toString());
}

final class InspectionLink implements Link {
  InspectionLink(this.path);
  @override
  final String path;
  @override
  bool existsSync() => path == 'link';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(invocation.memberName.toString());
}
