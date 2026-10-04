import 'package:dart_mobile_device/host/shared/posix_device_host.dart';

final class LinuxDeviceHost extends PosixDeviceHost {
  const LinuxDeviceHost(super.runner);

  @override
  String describeTunnelFailure(List<String> recent) {
    final guidance = super.describeTunnelFailure(recent);
    final detail = recent.join('\n');
    if (!detail.contains('Device is not connected') &&
        detail.contains('usbmuxd')) {
      return '${guidance}Start it with "sudo systemctl start usbmuxd", then retry.\n';
    }
    return guidance;
  }
}
