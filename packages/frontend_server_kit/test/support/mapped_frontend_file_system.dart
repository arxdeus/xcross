import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;

final class MappedFrontendFileSystem implements HostFileSystemInterface {
  MappedFrontendFileSystem(this.backingRoot, this.paths)
    : logicalRoot = '/frontend-${paths.basename(backingRoot)}';

  final String backingRoot;
  final String logicalRoot;
  final p.Context paths;
  final List<String> lookups = [];

  String map(String path) {
    lookups.add(path);
    final absolute = paths.absolute(path);
    if (absolute == logicalRoot) return backingRoot;
    if (!paths.isWithin(logicalRoot, absolute)) {
      throw StateError('outside selected namespace: $path');
    }
    return paths.join(backingRoot, paths.relative(absolute, from: logicalRoot));
  }

  @override
  File file(String path) => File(map(path));
  @override
  Directory directory(String path) => Directory(map(path));
  @override
  Link link(String path) => Link(map(path));
  @override
  void makeExecutable(String path) => throw UnsupportedError('unused');
  @override
  void setPermissions(String path, int mode) =>
      throw UnsupportedError('unused');
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError('unused');
}
