import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';

void main() {
  const usb = Device(
    name: 'USB iPhone',
    udid: 'USB-1',
    type: ConnectionType.usb,
  );
  const wifi = Device(
    name: 'Wi-Fi iPhone',
    udid: 'WIFI-1',
    type: ConnectionType.wifi,
    source: DeviceSource.tunneld,
  );

  group('PymdDeviceResolver.preferUsbCandidates', () {
    test('default all mode prefers attached USB over Wi-Fi', () {
      expect(
        PymdDeviceResolver.preferUsbCandidates(const [
          wifi,
          usb,
        ], mode: DeviceSearchMode.all),
        const [usb],
      );
    });

    test('all mode keeps Wi-Fi candidates when USB is absent', () {
      expect(
        PymdDeviceResolver.preferUsbCandidates(const [
          wifi,
        ], mode: DeviceSearchMode.all),
        const [wifi],
      );
    });

    test('explicit Wi-Fi mode is not rewritten', () {
      expect(
        PymdDeviceResolver.preferUsbCandidates(const [
          wifi,
          usb,
        ], mode: DeviceSearchMode.wifi),
        const [wifi, usb],
      );
    });

    test('multiple USB devices remain available for selection', () {
      const secondUsb = Device(
        name: 'Second USB iPhone',
        udid: 'USB-2',
        type: ConnectionType.usb,
      );
      expect(
        PymdDeviceResolver.preferUsbCandidates(const [
          wifi,
          usb,
          secondUsb,
        ], mode: DeviceSearchMode.all),
        const [usb, secondUsb],
      );
    });
  });
}
