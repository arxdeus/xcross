import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/src/shared/platform/permission_mode.dart';
import 'package:meta/meta.dart';
import 'package:posix/posix.dart' as posix;

@internal
final class MacOSPermissions implements HostPermissionsInterface {
  MacOSPermissions({void Function(String, String)? chmod})
    : _chmod = chmod ?? _nativeChmod;
  final void Function(String, String) _chmod;
  @override
  void setPermissions(String path, int mode) =>
      _chmod(path, octalPermissionMode(mode));
  static void _nativeChmod(String path, String mode) {
    if (posix.isPosixSupported) {
      posix.chmod(path, mode);
    }
  }
}
