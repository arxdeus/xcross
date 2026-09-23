import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';

void main() {
  test('preserves versioned framework directory and file links', () async {
    final temp = await Directory.systemTemp.createTemp('framework-copy-');
    addTearDown(() => temp.delete(recursive: true));
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

    await copyDirectoryPreservingSymlinks(source, destination);

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

    await copyDirectoryPreservingSymlinks(source, destination);
    expect(await Link(current).target(), 'A');
    expect(await File(alias).readAsString(), 'binary');
  });
}
