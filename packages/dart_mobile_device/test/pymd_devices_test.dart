import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/device.dart';
import 'package:dart_mobile_device/src/pymd_devices.dart';
import 'package:test/test.dart';

void main() {
  group('PymdDevices.parseDevices', () {
    // Captured verbatim from a real `pymobiledevice3 usbmux list` run
    // (10.3.0) against a connected USB iPhone.
    const usbSample = '''
[
    {
        "BuildVersion": "23D8133",
        "ConnectionType": "USB",
        "DeviceClass": "iPhone",
        "DeviceName": "iPhone Mind",
        "Identifier": "00008030-000664292232802E",
        "ProductType": "iPhone12,1",
        "ProductVersion": "26.3.1",
        "UniqueDeviceID": "00008030-000664292232802E"
    }
]''';

    test('parses name, udid, and USB connection type', () {
      final devices = PymdDevices.parseDevices(usbSample);
      expect(devices, hasLength(1));
      expect(devices.single.name, 'iPhone Mind');
      expect(devices.single.udid, '00008030-000664292232802E');
      expect(devices.single.type, ConnectionType.usb);
    });

    test('parses a Network connection type as wifi', () {
      const sample = '''
[
    {
        "ConnectionType": "Network",
        "DeviceName": "iPhone Mind",
        "UniqueDeviceID": "00008030-000664292232802E"
    }
]''';
      final devices = PymdDevices.parseDevices(sample);
      expect(devices.single.type, ConnectionType.wifi);
    });

    test('returns an empty list for an empty array', () {
      expect(PymdDevices.parseDevices('[]'), isEmpty);
    });

    test('parses multiple devices', () {
      const sample = '''
[
    {"ConnectionType": "USB", "DeviceName": "A", "UniqueDeviceID": "AAA"},
    {"ConnectionType": "Network", "DeviceName": "B", "UniqueDeviceID": "BBB"}
]''';
      final devices = PymdDevices.parseDevices(sample);
      expect(devices, hasLength(2));
      expect(devices[0].name, 'A');
      expect(devices[1].type, ConnectionType.wifi);
    });

    test('throws TunnelError when the top-level JSON is not an array', () {
      expect(() => PymdDevices.parseDevices('{}'), throwsA(isA<TunnelError>()));
    });
  });
}
