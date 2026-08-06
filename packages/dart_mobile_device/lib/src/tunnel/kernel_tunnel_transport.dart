import 'package:dart_mobile_device/src/models/device_endpoint.dart';
import 'package:dart_mobile_device/src/models/tunnel.dart';
import 'package:dart_mobile_device/src/transport/device_transport.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_daemon.dart';

/// RSD over the privileged tunnel published by `pymobiledevice3 remote
/// tunneld` (WinTun on Windows, utun on Linux).
///
/// The tunnel is a real host interface, so every device port is reachable
/// directly at [Tunnel.address] and no relay is needed.
class KernelTunnelTransport implements DeviceTransport {
  KernelTunnelTransport({
    required Tunnel tunnel,
    required int debugproxyPort,
    required TunnelDaemon daemon,
  }) : _tunnel = tunnel,
       _debugproxyPort = debugproxyPort,
       _daemon = daemon;

  final Tunnel _tunnel;
  final int _debugproxyPort;
  final TunnelDaemon _daemon;

  @override
  List<String> get pymdDeviceArgs => [
    '--rsd',
    _tunnel.address,
    '${_tunnel.port}',
  ];

  @override
  String get description => 'kernel RSD tunnel (${_tunnel.address})';

  @override
  Future<DeviceEndpoint> debugproxyEndpoint() async =>
      DeviceEndpoint(host: _tunnel.address, port: _debugproxyPort);

  @override
  Future<DeviceEndpoint> devicePortEndpoint(int devicePort) async =>
      DeviceEndpoint(host: _tunnel.address, port: devicePort);

  /// Stops only a daemon this session started; a tunneld the user runs
  /// themselves is left alone.
  @override
  Future<void> close() async => _daemon.stop();
}
