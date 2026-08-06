import 'package:meta/meta.dart';

/// A host/port pair this process can open a TCP socket to.
@immutable
final class DeviceEndpoint {
  const DeviceEndpoint({required this.host, required this.port});

  /// Host to connect to — a bare address, never bracketed.
  final String host;

  final int port;

  @override
  String toString() => '$host:$port';
}
