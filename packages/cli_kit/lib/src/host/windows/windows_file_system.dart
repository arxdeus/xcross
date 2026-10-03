import 'dart:io';

import 'package:cli_kit/src/shared/platform/platform_host.dart';

final class WindowsFileSystem implements HostFileSystemInterface {
  const WindowsFileSystem(this.paths);
  final HostPathsInterface paths;
  @override
  File file(String path) => File(paths.ioPath(path));
  @override
  Directory directory(String path) => Directory(paths.ioPath(path));
  @override
  Link link(String path) => Link(paths.ioPath(path));
  @override
  void makeExecutable(String path) {}
  @override
  void setPermissions(String path, int mode) {}
  @override
  Future<void> createArchiveLink(String destination, String target) async {
    final source = paths.context.isAbsolute(target)
        ? target
        : paths.context.join(paths.context.dirname(destination), target);
    await _copy(source, destination, <String>{});
  }

  Future<String> _canonicalDestination(String destination) async {
    var parent = destination;
    final suffix = <String>[];
    while (FileSystemEntity.typeSync(paths.ioPath(parent)) ==
        FileSystemEntityType.notFound) {
      suffix.insert(0, paths.context.basename(parent));
      final next = paths.context.dirname(parent);
      if (next == parent) {
        throw FileSystemException(
          'Archive link parent does not exist',
          destination,
        );
      }
      parent = next;
    }
    final canonical = await directory(parent).resolveSymbolicLinks();
    return paths.context.joinAll([canonical, ...suffix]);
  }

  Future<void> _copy(
    String source,
    String destination,
    Set<String> ancestors,
  ) async {
    final type = FileSystemEntity.typeSync(paths.ioPath(source));
    if (type == FileSystemEntityType.file) {
      await file(destination).parent.create(recursive: true);
      await file(source).copy(paths.ioPath(destination));
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException('Archive link target does not exist', source);
    }
    final canonical = await directory(source).resolveSymbolicLinks();
    final canonicalDestination = await _canonicalDestination(destination);
    final sourceKey = paths.pathKey(canonical);
    final destinationKey = paths.pathKey(canonicalDestination);
    if (sourceKey == destinationKey ||
        paths.context.isWithin(sourceKey, destinationKey)) {
      throw FileSystemException(
        'Archive link destination is inside its target',
        destination,
      );
    }
    if (!ancestors.add(canonical)) {
      throw FileSystemException('Archive link cycle', source);
    }
    try {
      await directory(destination).create(recursive: true);
      await for (final child in directory(source).list(followLinks: false)) {
        await _copy(
          child.path,
          paths.context.join(destination, paths.context.basename(child.path)),
          ancestors,
        );
      }
    } finally {
      ancestors.remove(canonical);
    }
  }
}
