import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:meta/meta.dart';

@internal
final class WindowsAppleFilePermissions implements AppleFilePermissions {
  const WindowsAppleFilePermissions();

  @override
  void harden(String path) {}

  @override
  void preserve(String path, int mode) {}
}
