/// A user-facing error from device transport, tunnels, or pymobiledevice3.
class TunnelError implements Exception {
  TunnelError(this.message);

  final String message;

  @override
  String toString() => message;
}
