import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;

final class RecursiveDirectoryCopier {
  const RecursiveDirectoryCopier({
    required this.fileSystem,
    required this.paths,
  });

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  Future<void> copy(String source, String destination) async {
    final pendingLinks = <(String, String)>[];
    await _copyRegularEntries(source, destination, pendingLinks);
    await _createPendingLinks(pendingLinks);
  }

  Future<void> _copyRegularEntries(
    String source,
    String destination,
    List<(String, String)> pendingLinks,
  ) async {
    await fileSystem.directory(destination).create(recursive: true);
    await for (final entity
        in fileSystem.directory(source).list(followLinks: false)) {
      final destPath = paths.join(destination, paths.basename(entity.path));
      if (entity is Directory) {
        await _copyRegularEntries(entity.path, destPath, pendingLinks);
      } else if (entity is File) {
        await fileSystem.file(entity.path).copy(fileSystem.file(destPath).path);
      } else if (entity is Link) {
        pendingLinks.add((
          destPath,
          await fileSystem.link(entity.path).target(),
        ));
      }
    }
  }

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
      for (final (path, target) in pendingLinks) {
        await _replaceLink(path, target);
      }
      break;
    }
  }

  bool _linkTargetExists(String linkPath, String target) {
    final resolvedTarget = paths.isAbsolute(target)
        ? target
        : paths.normalize(paths.join(paths.dirname(linkPath), target));
    return fileSystem.file(resolvedTarget).existsSync() ||
        fileSystem.directory(resolvedTarget).existsSync();
  }

  Future<void> _replaceLink(String path, String target) async {
    final link = fileSystem.link(path);
    if (link.existsSync()) {
      await link.delete();
    }
    await link.create(target);
  }
}
