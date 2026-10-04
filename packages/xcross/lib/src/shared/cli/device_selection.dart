import 'package:dart_mobile_device/shared/device/models/device.dart';
import 'package:meta/meta.dart';

@internal
enum DeviceConnection { attached, wireless, both }

@internal
DeviceSearchMode deviceSearchMode({
  required bool usb,
  required bool wifi,
  required DeviceConnection deviceConnection,
}) {
  if (usb) return DeviceSearchMode.usb;
  if (wifi) return DeviceSearchMode.wifi;
  return switch (deviceConnection) {
    DeviceConnection.attached => DeviceSearchMode.usb,
    DeviceConnection.wireless => DeviceSearchMode.wifi,
    DeviceConnection.both => DeviceSearchMode.all,
  };
}
