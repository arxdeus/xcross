import 'package:dart_mobile_device/dart_mobile_device.dart';

enum DeviceConnection { attached, wireless, both }

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
