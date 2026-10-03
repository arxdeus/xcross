import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/src/shared/host/device_host_policy.dart';
import 'package:dart_mobile_device/src/shared/preparation/tunnel_failure_guidance.dart';

abstract base class PosixDeviceHost implements DeviceHostPolicy {
  const PosixDeviceHost(this.runner);
  final ProcessRunner runner;
  List<String> get pipxDirectories {
    final env = runner.effectiveEnvironment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    return [
      if (env['PIPX_BIN_DIR'] case final String configured
          when configured.isNotEmpty)
        configured,
      if (home != null && home.isNotEmpty)
        runner.host.paths.context.join(home, '.local', 'bin'),
    ];
  }

  @override
  String get preparationDeniedMessage =>
      'xcross needs elevated privileges to create the RSD tunnel.\n'
      'Run the displayed preparation steps with an authorized account.';

  @override
  String describeTunnelFailure(List<String> recent) =>
      describeDeviceTunnelFailure(recent);

  @override
  String get installCommand =>
      'pipx install pymobiledevice3 && pipx ensurepath';

  @override
  String elevatedCommand(String arguments) => 'sudo pymobiledevice3 $arguments';

  @override
  Future<String?> resolvePipx() =>
      runner.which('pipx', extraDirectories: pipxDirectories);

  @override
  Future<bool> lockdownTunnelLooksAlive() async {
    try {
      final result = await runner.run(await runner.locateTool('pgrep'), [
        '-f',
        'pymobiledevice3.*lockdown.*start-tunnel',
      ]);
      return result.exitCode == 0 && result.stdout.trim().isNotEmpty;
    } on Object {
      return false;
    }
  }
}
