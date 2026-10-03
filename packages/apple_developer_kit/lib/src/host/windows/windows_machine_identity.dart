import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:cli_kit/cli_kit_shared.dart' show CapturedProcess;

final class WindowsMachineIdentity implements MachineIdentityProvider {
  WindowsMachineIdentity(this.run, this.locate);

  final Future<CapturedProcess> Function(
    String executable,
    List<String> arguments,
  )
  run;
  final Future<String> Function(String name) locate;

  @override
  Future<String> read() async {
    try {
      final result = await run(await locate('reg'), const [
        'query',
        r'HKLM\SOFTWARE\Microsoft\Cryptography',
        '/v',
        'MachineGuid',
      ]);
      if (result.exitCode != 0) return '';
      return RegExp(
            r'MachineGuid\s+REG_SZ\s+(\S+)',
          ).firstMatch(result.stdout)?[1] ??
          '';
    } on Object {
      return '';
    }
  }
}
