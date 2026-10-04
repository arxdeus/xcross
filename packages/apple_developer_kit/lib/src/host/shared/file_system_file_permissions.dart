import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

@internal
final class FileSystemAppleFilePermissions implements AppleFilePermissions {
  FileSystemAppleFilePermissions(this.files);

  final HostFileSystemInterface files;

  @override
  void harden(String path) {
    try {
      files.setPermissions(path, 0x180);
    } on Object {
      return;
    }
  }

  @override
  void preserve(String path, int mode) => files.setPermissions(path, mode);
}
