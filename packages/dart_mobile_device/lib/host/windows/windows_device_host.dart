import 'package:cli_kit/shared/process/process.dart';
import 'package:dart_mobile_device/shared/host/device_host_policy.dart';
import 'package:dart_mobile_device/src/shared/preparation/tunnel_failure_guidance.dart';

final class WindowsDeviceHost implements DeviceHostPolicy {
  const WindowsDeviceHost(this.runner);
  final ProcessRunner runner;

  @override
  String get preparationDeniedMessage =>
      'xcross needs Administrator rights to create the Windows RSD tunnel.\n'
      'Open PowerShell with "Run as administrator", then run:\n'
      '    xcross tunnel';

  @override
  String describeTunnelFailure(List<String> recent) =>
      describeDeviceTunnelFailure(recent);

  @override
  String get installCommand =>
      'py -m pip install --prefer-binary -U pymobiledevice3';

  @override
  String elevatedCommand(String arguments) => 'pymobiledevice3 $arguments';

  @override
  Future<String?> resolvePipx() async => null;

  @override
  Future<bool> lockdownTunnelLooksAlive() async {
    try {
      final result = await runner.run(
        await runner.locateTool('powershell'),
        const [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r"Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'lockdown.*start-tunnel|start-tunnel' } | Select-Object -First 1 -ExpandProperty ProcessId",
        ],
      );
      return result.exitCode == 0 && result.stdout.trim().isNotEmpty;
    } on Object {
      return false;
    }
  }
}
