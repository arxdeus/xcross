import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';

final class PosixSwiftPmArtifactFileSystem
    implements SwiftPmArtifactFileSystem {
  const PosixSwiftPmArtifactFileSystem(this.host);
  final PlatformHostInterface host;
  @override
  Future<bool> isLinkOrReparsePoint(String path) async =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link;
  @override
  Future<void> createAlias(String alias, String target) =>
      Link(alias).create(target);
  @override
  Future<void> deleteAlias(String alias) => Link(alias).delete();
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
            await Directory(alias).resolveSymbolicLinks(),
          ) ==
          host.paths.pathKey(target);
    } on FileSystemException {
      return false;
    }
  }
}
