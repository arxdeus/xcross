import 'package:meta/meta.dart';

/// A host/port pair this process can open a TCP socket to.
///
/// Kernel-tunnel transports point straight at the device's RSD address, while
/// userspace transports point at a loopback relay. Consumers only ever need the
/// pair, so they stay agnostic of which transport produced it.
@immutable
class DeviceEndpoint {
  const DeviceEndpoint({required this.host, required this.port});

  /// Host to connect to — a bare address, never bracketed.
  final String host;

  final int port;

  @override
  String toString() => '$host:$port';
}
