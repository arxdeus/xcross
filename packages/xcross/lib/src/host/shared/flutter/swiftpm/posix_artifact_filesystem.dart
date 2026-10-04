import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';

@internal
final class PosixSwiftPmArtifactFileSystem
    implements SwiftPmArtifactFileSystem {
  const PosixSwiftPmArtifactFileSystem(this.host);
  final PlatformHostInterface host;
  @override
  File file(String path) => host.fileSystem.file(host.paths.ioPath(path));
  @override
  Directory directory(String path) =>
      host.fileSystem.directory(host.paths.ioPath(path));
  @override
  Link link(String path) => host.fileSystem.link(host.paths.ioPath(path));
  @override
  FileSystemEntityType typeSync(String path, {bool followLinks = true}) =>
      FileSystemEntity.typeSync(
        host.paths.ioPath(path),
        followLinks: followLinks,
      );
  @override
  Future<bool> isLinkOrReparsePoint(String path) async =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link;
  @override
  Future<void> createAlias(String alias, String target) =>
      link(alias).create(target);
  @override
  Future<void> deleteAlias(String alias) => link(alias).delete();
  @override
  String processPath(String path) => path;
  @override
  Future<bool> isAliasTo(String alias, String target) async {
    if (FileSystemEntity.typeSync(alias, followLinks: false) !=
        FileSystemEntityType.link) {
      return false;
    }
    try {
      return host.paths.pathKey(
            await directory(alias).resolveSymbolicLinks(),
          ) ==
          host.paths.pathKey(target);
    } on FileSystemException {
      return false;
    }
  }
}
