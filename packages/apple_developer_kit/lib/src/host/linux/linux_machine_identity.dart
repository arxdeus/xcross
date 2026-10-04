import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

@internal
final class LinuxMachineIdentity implements MachineIdentityProvider {
  LinuxMachineIdentity(
    this.files, {
    this.paths = const ['/etc/machine-id', '/var/lib/dbus/machine-id'],
  });

  final HostFileSystemInterface files;
  final List<String> paths;

  @override
  Future<String> read() async {
    try {
      for (final path in paths) {
        final file = files.file(path);
        if (!file.existsSync()) continue;
        final value = (await file.readAsString()).trim();
        if (value.isNotEmpty) return value;
      }
    } on Object {
      return '';
    }
    return '';
  }
}
