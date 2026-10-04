import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

@internal
final class NativeFileSystem implements HostFileSystemInterface {
  const NativeFileSystem(this.paths, {required this.permissions});
  final HostPathsInterface paths;
  final HostPermissionsInterface permissions;
  @override
  File file(String path) => File(paths.ioPath(path));
  @override
  Directory directory(String path) => Directory(paths.ioPath(path));
  @override
  Link link(String path) => Link(paths.ioPath(path));
  @override
  void makeExecutable(String path) {
    setPermissions(path, 0x1ed);
  }

  @override
  void setPermissions(String path, int mode) =>
      permissions.setPermissions(paths.ioPath(path), mode);

  @override
  Future<void> createArchiveLink(String destination, String target) =>
      link(destination).create(target);
}
