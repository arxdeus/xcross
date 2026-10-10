import 'dart:io';

import 'package:cli_kit/shared/platform/file_system_inspection.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/shared/flutter/flutter_workspace_overlay.dart';

/// Whether a workspace still matches the layout [FlutterWorkspaceOverlay]
/// would create now, so a partial, stale or written-through workspace is
/// rebuilt rather than reused.
@internal
final class FlutterWorkspaceReadiness<T extends PlatformHostInterface> {
  const FlutterWorkspaceReadiness(this.engineCache);
  final IosEngineCache<T> engineCache;
  p.Context get paths => engineCache.host.paths.context;
  HostFileSystemInterface get fileSystem => engineCache.host.fileSystem;

  Future<bool> isReady({
    required String flutterRoot,
    required String workspaceRoot,
  }) async {
    try {
      final plan = FlutterWorkspaceOverlay(
        engineCache,
      ).plan(flutterRoot: flutterRoot, workspaceRoot: workspaceRoot);
      for (final entry in plan) {
        if (!await _matches(entry, plan)) return false;
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _matches(
    FlutterWorkspaceEntry entry,
    List<FlutterWorkspaceEntry> plan,
  ) async {
    final path = entry.path;
    final type = fileSystem.typeSync(path, followLinks: false);
    switch (entry) {
      case FlutterWorkspaceDirectory(:final exact):
        if (type != FileSystemEntityType.directory) return false;
        if (!exact) return true;
        final key = engineCache.host.paths.pathKey(path);
        final planned = {
          for (final child in plan)
            if (engineCache.host.paths.pathKey(paths.dirname(child.path)) ==
                key)
              paths.basename(child.path),
        };
        return fileSystem
            .directory(path)
            .listSync(followLinks: false)
            .every((child) => planned.contains(paths.basename(child.path)));
      case FlutterWorkspaceCopy(:final source):
        return type == FileSystemEntityType.file &&
            await fileSystem.file(path).length() ==
                await fileSystem.file(source).length();
      case FlutterWorkspaceFile(:final contents):
        return type == FileSystemEntityType.file &&
            await fileSystem.file(path).readAsString() == contents;
      case FlutterWorkspaceLink(:final target):
        if (type == FileSystemEntityType.directory ||
            type == FileSystemEntityType.notFound) {
          return false;
        }
        if (type == FileSystemEntityType.file) {
          return _sameFile(path, target);
        }
        final host = engineCache.host;
        return host.paths.pathKey(
              await fileSystem.file(path).resolveSymbolicLinks(),
            ) ==
            host.paths.pathKey(
              await fileSystem.file(target).resolveSymbolicLinks(),
            );
    }
  }

  /// A file leaf the host linked by hard link or copied, which still has its
  /// target's size and modification time.
  bool _sameFile(String path, String target) {
    if (fileSystem.typeSync(target) != FileSystemEntityType.file) return false;
    final file = fileSystem.file(path);
    final source = fileSystem.file(target);
    return file.lengthSync() == source.lengthSync() &&
        file.lastModifiedSync() == source.lastModifiedSync();
  }
}
