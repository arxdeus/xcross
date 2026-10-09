import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';

/// Plain `dart:io` filesystem for tests that only touch files and folders.
final class IoFileSystem implements HostFileSystemInterface {
  const IoFileSystem();
  @override
  File file(String path) => File(path);
  @override
  Directory directory(String path) => Directory(path);
  @override
  Link link(String path) => Link(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
