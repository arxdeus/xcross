import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/src/shared/host/device_host_policy.dart';

final class WindowsDeviceHost implements DeviceHostPolicy {
  const WindowsDeviceHost(this.runner);
  final ProcessRunner runner;

  @override
  String get installCommand => 'py -m pip install -U pymobiledevice3';

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
