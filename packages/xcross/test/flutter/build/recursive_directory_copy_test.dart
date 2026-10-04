import 'dart:io';

import 'package:cli_kit/composition/native_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';

void main() {
  test('preserves versioned framework directory and file links', () async {
    final temp = await Directory.systemTemp.createTemp('framework-copy-');
    addTearDown(() => temp.delete(recursive: true));
    final host = detectPlatformHost();
    final copier = RecursiveDirectoryCopier(
      fileSystem: host.fileSystem,
      paths: host.paths.context,
    );
    final source = p.join(temp.path, 'Source.framework');
    final destination = p.join(temp.path, 'Copied.framework');
    final version = Directory(p.join(source, 'Versions', 'A'));
    await version.create(recursive: true);
    await File(p.join(version.path, 'Source')).writeAsString('binary');
    await Link(p.join(source, 'Versions', 'Current')).create('A');
    await Link(
      p.join(source, 'Source'),
    ).create(p.join('Versions', 'Current', 'Source'));
    await Link(p.join(source, 'Alias')).create('Source');

    await copier.copy(source, destination);

    final current = p.join(destination, 'Versions', 'Current');
    final binary = p.join(destination, 'Source');
    final alias = p.join(destination, 'Alias');
    expect(
      FileSystemEntity.typeSync(current, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(
      FileSystemEntity.typeSync(binary, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await Link(current).target(), 'A');
    expect(
      await Link(binary).target(),
      p.join('Versions', 'Current', 'Source'),
    );
    expect(
      FileSystemEntity.typeSync(alias, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await Link(alias).target(), 'Source');
    expect(await File(binary).readAsString(), 'binary');
    expect(await File(alias).readAsString(), 'binary');

    await copier.copy(source, destination);
    expect(await Link(current).target(), 'A');
    expect(await File(alias).readAsString(), 'binary');
  });

  test(
    'maps selected destinations and preserves links without following them',
    () async {
      final temp = await Directory.systemTemp.createTemp('mapped-copy-');
      addTearDown(() => temp.delete(recursive: true));
      final paths = p.Context(style: p.Style.posix);
      final logicalRoot = '/virtual-${paths.basename(temp.path)}';
      final files = MappedCopyFileSystem(
        logicalRoot: logicalRoot,
        backingRoot: temp.path,
        paths: paths,
      );
      final source = paths.join(logicalRoot, 'source');
      final destination = paths.join(logicalRoot, 'destination');
      await files
          .directory(paths.join(source, 'nested'))
          .create(recursive: true);
      await files
          .file(paths.join(source, 'nested', 'value'))
          .writeAsString('data');
      await files.file(paths.join(source, 'plain')).writeAsString('plain data');
      await files.link(paths.join(source, 'first')).create('second');
      await files.link(paths.join(source, 'second')).create('nested/value');
      await files.link(paths.join(source, 'directory')).create('nested');
      await files.link(paths.join(source, 'dangling')).create('missing');
      await files.link(paths.join(source, 'cycle-a')).create('cycle-b');
      await files.link(paths.join(source, 'cycle-b')).create('cycle-a');
      final outside = Directory(paths.join(temp.path, 'outside'));
      await outside.create();
      await File(paths.join(outside.path, 'secret')).writeAsString('untouched');
      await files.link(paths.join(source, 'external')).create(outside.path);
      final copier = RecursiveDirectoryCopier(fileSystem: files, paths: paths);

      await copier.copy(source, destination);
      await copier.copy(source, destination);

      expect(
        await files.file(paths.join(destination, 'plain')).readAsString(),
        'plain data',
      );
      expect(
        await files.file(paths.join(destination, 'first')).readAsString(),
        'data',
      );
      expect(
        await files.link(paths.join(destination, 'first')).target(),
        'second',
      );
      expect(
        await files.link(paths.join(destination, 'second')).target(),
        'nested/value',
      );
      expect(
        await files.link(paths.join(destination, 'directory')).target(),
        'nested',
      );
      expect(
        await files.link(paths.join(destination, 'dangling')).target(),
        'missing',
      );
      expect(
        await files.link(paths.join(destination, 'cycle-a')).target(),
        'cycle-b',
      );
      expect(
        await files.link(paths.join(destination, 'cycle-b')).target(),
        'cycle-a',
      );
      expect(
        await files.link(paths.join(destination, 'external')).target(),
        outside.path,
      );
      expect(
        await File(paths.join(outside.path, 'secret')).readAsString(),
        'untouched',
      );
      expect(Directory(logicalRoot).existsSync(), isFalse);
      expect(files.lookups, contains(paths.join(destination, 'plain')));
      expect(
        files.lookups,
        contains(paths.join(destination, 'nested', 'value')),
      );
      expect(
        files.lookups,
        isNot(contains(paths.join(source, 'external', 'secret'))),
      );
    },
  );

  test(
    'rejects mapped destination link collisions without modifying targets',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'mapped-copy-collision-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final paths = p.Context(style: p.Style.posix);
      final logicalRoot = '/virtual-${paths.basename(temp.path)}';
      final files = MappedCopyFileSystem(
        logicalRoot: logicalRoot,
        backingRoot: temp.path,
        paths: paths,
      );
      final source = paths.join(logicalRoot, 'source');
      final destination = paths.join(logicalRoot, 'destination');
      await files
          .directory(paths.join(source, 'nested'))
          .create(recursive: true);
      await files
          .file(paths.join(source, 'nested', 'value'))
          .writeAsString('replacement');
      await files.directory(destination).create();
      final outside = Directory(paths.join(temp.path, 'outside'));
      await outside.create();
      final outsideFile = File(paths.join(outside.path, 'value'));
      await outsideFile.writeAsString('untouched');
      final nested = paths.join(destination, 'nested');
      await files.link(nested).create(outside.path);
      final copier = RecursiveDirectoryCopier(fileSystem: files, paths: paths);

      await expectLater(
        copier.copy(source, destination),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.path,
            'path',
            nested,
          ),
        ),
      );
      expect(await outsideFile.readAsString(), 'untouched');
      expect(await files.link(nested).target(), outside.path);

      await files.link(nested).delete();
      await files.directory(nested).create();
      final copiedFile = paths.join(nested, 'value');
      await files.link(copiedFile).create(outsideFile.path);
      await expectLater(
        copier.copy(source, destination),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.path,
            'path',
            copiedFile,
          ),
        ),
      );
      expect(await outsideFile.readAsString(), 'untouched');
      expect(await files.link(copiedFile).target(), outsideFile.path);
      expect(Directory(logicalRoot).existsSync(), isFalse);
    },
  );
}

@internal
final class MappedCopyFileSystem implements HostFileSystemInterface {
  MappedCopyFileSystem({
    required this.logicalRoot,
    required this.backingRoot,
    required this.paths,
  });

  final String logicalRoot;
  final String backingRoot;
  final p.Context paths;
  final List<String> lookups = [];

  String map(String path) {
    lookups.add(path);
    if (path == logicalRoot) return backingRoot;
    if (paths.isWithin(logicalRoot, path)) {
      return paths.join(backingRoot, paths.relative(path, from: logicalRoot));
    }
    return path;
  }

  @override
  File file(String path) => File(map(path));

  @override
  Directory directory(String path) => Directory(map(path));

  @override
  Link link(String path) => Link(map(path));

  @override
  void makeExecutable(String path) => throw UnsupportedError('not used');

  @override
  void setPermissions(String path, int mode) =>
      throw UnsupportedError('not used');

  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError('copy must preserve link primitives');
}
