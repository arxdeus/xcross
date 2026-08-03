import 'package:test/test.dart';
import 'package:dart_mobile_device/src/models/device.dart';

void main() {
  group('ConnectionType.parse', () {
    test('usb', () => expect(ConnectionType.parse('usb'), ConnectionType.usb));
    test('USB', () => expect(ConnectionType.parse('USB'), ConnectionType.usb));
    test(
      'wifi',
      () => expect(ConnectionType.parse('wifi'), ConnectionType.wifi),
    );
    test(
      'WIFI is case-insensitive',
      () => expect(ConnectionType.parse('WIFI'), ConnectionType.wifi),
    );
    // pymobiledevice3 uses `Network` for wireless-connected devices.
    test(
      'network maps to wifi',
      () => expect(ConnectionType.parse('network'), ConnectionType.wifi),
    );
    test(
      'NETWORK is case-insensitive',
      () => expect(ConnectionType.parse('NETWORK'), ConnectionType.wifi),
    );
    test(
      'unrecognized values fall back to usb',
      () => expect(ConnectionType.parse('anything-else'), ConnectionType.usb),
    );
    test(
      'empty string falls back to usb',
      () => expect(ConnectionType.parse(''), ConnectionType.usb),
    );
  });

  group('Device.toString', () {
    test('formats as "name [type]: udid"', () {
      const device = Device(
        name: 'iPhone 15',
        udid: 'ABC123',
        type: ConnectionType.usb,
      );

      expect(device.toString(), 'iPhone 15 [usb]: ABC123');
    });
  });
}
