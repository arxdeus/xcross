import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:cli_kit/cli_kit_shared.dart' show HostFileSystemInterface;

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
