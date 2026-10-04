import 'dart:io';
import 'package:meta/meta.dart';

@internal
abstract interface class SwiftPmArtifactFileSystem {
  File file(String path);
  Directory directory(String path);
  Link link(String path);
  FileSystemEntityType typeSync(String path, {bool followLinks = true});
  Future<bool> isLinkOrReparsePoint(String path);
  Future<void> createAlias(String alias, String target);
  Future<bool> isAliasTo(String alias, String target);
  Future<void> deleteAlias(String alias);
  String processPath(String path);
}
