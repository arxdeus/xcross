import 'package:meta/meta.dart';

/// RSD tunnel endpoint for a device.
@immutable
class Tunnel {
  const Tunnel({required this.address, required this.port});

  /// Tunnel IPv6 (or v4) address of the device.
  final String address;

  /// RSD handshake port.
  final int port;
}
