import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';

final class WindowsAppleFilePermissions implements AppleFilePermissions {
  const WindowsAppleFilePermissions();

  @override
  void harden(String path) {}

  @override
  void preserve(String path, int mode) {}
}
