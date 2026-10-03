import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:posix/posix.dart' as posix;

final class PosixAppleFilePermissions implements AppleFilePermissions {
  const PosixAppleFilePermissions();

  @override
  void harden(String path) {
    try {
      posix.chmod(path, '0600');
    } on Object {
      return;
    }
  }

  @override
  void preserve(String path, int mode) =>
      posix.chmod(path, mode.toRadixString(8).padLeft(4, '0'));
}
