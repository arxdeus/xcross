import 'dart:io';

import 'package:path/path.dart' as p;

/// Recursively copies [src] to [dst], preserving symbolic links.
Future<void> copyDirectoryPreservingSymlinks(String src, String dst) async {
  final pendingLinks = <(String, String)>[];
  await _copyRegularEntries(src, dst, pendingLinks);
  await _createPendingLinks(pendingLinks);
}

/// Copy directories and files, collecting `(path, target)` for each link.
Future<void> _copyRegularEntries(
  String source,
  String destination,
  List<(String, String)> pendingLinks,
) async {
  await Directory(destination).create(recursive: true);
  await for (final entity in Directory(source).list(followLinks: false)) {
    final destPath = p.join(destination, p.basename(entity.path));
    if (entity is Directory) {
      await _copyRegularEntries(entity.path, destPath, pendingLinks);
    } else if (entity is File) {
      await entity.copy(destPath);
    } else if (entity is Link) {
      pendingLinks.add((destPath, await entity.target()));
    }
  }
}

/// On Windows the link kind depends on the target type when Link.create is
/// called. Defer links until their regular-file targets have been copied,
/// repeating so links to links resolve in dependency order.
Future<void> _createPendingLinks(List<(String, String)> pendingLinks) async {
  while (pendingLinks.isNotEmpty) {
    var created = false;
    for (var index = pendingLinks.length - 1; index >= 0; index--) {
      final (path, target) = pendingLinks[index];
      if (!_linkTargetExists(path, target)) continue;
      await _replaceLink(path, target);
      pendingLinks.removeAt(index);
      created = true;
    }
    if (created) continue;
    // Preserve dangling links too; their target kind is unknowable locally.
    for (final (path, target) in pendingLinks) {
      await _replaceLink(path, target);
    }
    break;
  }
}

bool _linkTargetExists(String linkPath, String target) {
  final resolvedTarget = p.isAbsolute(target)
      ? target
      : p.normalize(p.join(p.dirname(linkPath), target));
  return FileSystemEntity.typeSync(resolvedTarget) !=
      FileSystemEntityType.notFound;
}

Future<void> _replaceLink(String path, String target) async {
  final link = Link(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    await link.delete();
  }
  await link.create(target);
}
