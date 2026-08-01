import 'package:meta/meta.dart';

/// Which devices to search for.
enum DeviceSearchMode { all, usb, wifi }

/// How a device is connected.
enum ConnectionType {
  usb,
  wifi;

  static ConnectionType parse(String raw) {
    final v = raw.toLowerCase();
    // pymobiledevice3 reports wireless devices as `Network`.
    return (v == 'wifi' || v == 'network')
        ? ConnectionType.wifi
        : ConnectionType.usb;
  }
}

/// A connected iOS device.
@immutable
class Device {
  const Device({required this.name, required this.udid, required this.type});

  /// Human-readable device name.
  final String name;

  /// Unique device identifier.
  final String udid;

  /// Connection type (USB or Wi-Fi).
  final ConnectionType type;

  @override
  String toString() => '$name [${type.name}]: $udid';
}
