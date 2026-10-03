import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:cli_kit/cli_kit_shared.dart' show CapturedProcess;

final class MacOSMachineIdentity implements MachineIdentityProvider {
  MacOSMachineIdentity(this.run);

  final Future<CapturedProcess> Function(
    String executable,
    List<String> arguments,
  )
  run;

  @override
  Future<String> read() async {
    try {
      final result = await run('/usr/sbin/ioreg', const [
        '-rd1',
        '-c',
        'IOPlatformExpertDevice',
      ]);
      if (result.exitCode != 0) return '';
      return RegExp(
            r'"IOPlatformUUID"\s*=\s*"([^"]+)"',
          ).firstMatch(result.stdout)?[1] ??
          '';
    } on Object {
      return '';
    }
  }
}
