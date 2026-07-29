import 'package:meta/meta.dart';

/// How a device is connected.
enum ConnectionType {
  usb,
  wifi;

  static ConnectionType parse(String raw) {
    final v = raw.toLowerCase();
    // Upstream xtool prints `[network]` for wireless devices.
    return (v == 'wifi' || v == 'network')
        ? ConnectionType.wifi
        : ConnectionType.usb;
  }
}

/// A device as reported by `xtool devices`.
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
