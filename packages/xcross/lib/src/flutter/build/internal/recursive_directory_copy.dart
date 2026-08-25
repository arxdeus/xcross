import 'dart:io';

import 'package:path/path.dart' as p;

/// Recursively copies [src] to [dst], preserving symbolic links.
Future<void> copyDirectoryPreservingSymlinks(String src, String dst) async {
  await Directory(dst).create(recursive: true);
  await for (final entity in Directory(src).list()) {
    final destPath = p.join(dst, p.basename(entity.path));
    if (entity is Directory) {
      await copyDirectoryPreservingSymlinks(entity.path, destPath);
    } else if (entity is File) {
      await entity.copy(destPath);
    } else if (entity is Link) {
      final link = Link(destPath);
      if (link.existsSync()) await link.delete();
      await link.create(await entity.target());
    }
  }
}
