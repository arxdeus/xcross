import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

/// `dart:io` backed file system using the test host's own path style, for
/// tests on real temp directories (`testIPhoneRuntime()` is POSIX only and
/// mangles Windows temp paths).
@internal
final class NativeTestFileSystem implements HostFileSystemInterface {
  const NativeTestFileSystem();

  @override
  File file(String path) => File(path);

  @override
  Directory directory(String path) => Directory(path);

  @override
  Link link(String path) => Link(path);

  @override
  void makeExecutable(String path) {}

  @override
  void setPermissions(String path, int mode) {}

  @override
  Future<void> createArchiveLink(String destination, String target) =>
      Link(destination).create(target);
}
