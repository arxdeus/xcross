import 'dart:io';

import 'package:path/path.dart' as p;

/// Recursively copies [src] to [dst], preserving symbolic links.
Future<void> copyDirectoryPreservingSymlinks(String src, String dst) async {
  final pendingLinks = <(String, String)>[];

  Future<void> copyRegularEntries(String source, String destination) async {
    await Directory(destination).create(recursive: true);
    await for (final entity in Directory(source).list(followLinks: false)) {
      final destPath = p.join(destination, p.basename(entity.path));
      if (entity is Directory) {
        await copyRegularEntries(entity.path, destPath);
      } else if (entity is File) {
        await entity.copy(destPath);
      } else if (entity is Link) {
        pendingLinks.add((destPath, await entity.target()));
      }
    }
  }

  await copyRegularEntries(src, dst);
  // On Windows the link kind depends on the target type when Link.create is
  // called. Defer links until their regular-file targets have been copied.
  Future<void> createLink(String path, String target) async {
    final link = Link(path);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      await link.delete();
    }
    await link.create(target);
  }

  while (pendingLinks.isNotEmpty) {
    var created = false;
    for (var index = pendingLinks.length - 1; index >= 0; index--) {
      final (path, target) = pendingLinks[index];
      final resolvedTarget = p.isAbsolute(target)
          ? target
          : p.normalize(p.join(p.dirname(path), target));
      if (FileSystemEntity.typeSync(resolvedTarget) ==
          FileSystemEntityType.notFound) {
        continue;
      }
      await createLink(path, target);
      pendingLinks.removeAt(index);
      created = true;
    }
    if (created) continue;
    // Preserve dangling links too; their target kind is unknowable locally.
    for (final (path, target) in pendingLinks) {
      await createLink(path, target);
    }
    break;
  }
}
