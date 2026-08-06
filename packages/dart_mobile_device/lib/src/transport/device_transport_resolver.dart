import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/constants.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:dart_mobile_device/src/transport/device_transport.dart';
import 'package:dart_mobile_device/src/transport/internal/device_transport_mode.dart';
import 'package:dart_mobile_device/src/tunnel/kernel_tunnel_transport.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_daemon.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_discovery.dart';
import 'package:dart_mobile_device/src/tunnel/userspace_tunnel_transport.dart';

/// Builds the [DeviceTransport] for a session, preferring the kernel tunnel
/// and falling back to the userspace tunnel when it is unusable.
abstract final class DeviceTransportResolver {
  /// `auto` (default), `kernel`, or `userspace`.
  static const String modeEnvironmentVariable = 'XCROSS_TUNNEL_MODE';

  static Future<DeviceTransport> resolve({
    required String udid,
    Duration discoveryTimeout = const Duration(seconds: 60),
  }) async {
    final mode = _modeFromEnvironment();
    switch (mode) {
      case DeviceTransportMode.userspace:
        return UserspaceTunnelTransport(udid: udid);
      case DeviceTransportMode.kernel:
        return _kernelTransport(udid: udid, discoveryTimeout: discoveryTimeout);
      case DeviceTransportMode.auto:
        try {
          return await _kernelTransport(
            udid: udid,
            discoveryTimeout: discoveryTimeout,
          );
        } on TunnelError catch (error) {
          if (_deviceIsMissingDebugproxy(error.message)) rethrow;
          Log.logWarn(
            'kernel RSD tunnel unusable — continuing over the userspace '
            'tunnel (usbmux + loopback)',
          );
          Log.logTrace(error.message);
          return UserspaceTunnelTransport(udid: udid);
        }
    }
  }

  static DeviceTransportMode _modeFromEnvironment() {
    final value = Platform.environment[modeEnvironmentVariable]
        ?.trim()
        .toLowerCase();
    return switch (value) {
      null || '' || 'auto' => DeviceTransportMode.auto,
      'kernel' || 'tunneld' => DeviceTransportMode.kernel,
      'userspace' => DeviceTransportMode.userspace,
      _ => DeviceTransportMode.auto,
    };
  }

  static Future<DeviceTransport> _kernelTransport({
    required String udid,
    required Duration discoveryTimeout,
  }) async {
    final daemon = TunnelDaemon();
    try {
      await daemon.ensureRunning();
      final tunnel = await TunnelDiscovery.discoverTunnel(
        udid: udid,
        timeout: discoveryTimeout,
      );
      Log.logTrace('connecting to RSD at ${tunnel.address}:${tunnel.port}');
      final debugproxyPort = await _debugproxyPort(tunnel);
      return KernelTunnelTransport(
        tunnel: tunnel,
        debugproxyPort: debugproxyPort,
        daemon: daemon,
      );
    } on Object {
      daemon.stop();
      rethrow;
    }
  }

  static Future<int> _debugproxyPort(Tunnel tunnel) async {
    try {
      return await Pymd.rsdServicePort(
        rsdHost: tunnel.address,
        rsdPort: tunnel.port,
        service: TunnelConstants.debugproxyService,
      );
    } on TunnelError catch (error) {
      final detail = error.message;
      if (_deviceIsMissingDebugproxy(detail)) {
        throw TunnelError(
          "Developer Disk Image not mounted — the device doesn't expose the "
          'debugproxy service. Mount it and retry:\n\n'
          '    xcross tunnel\n\n'
          'Or manually:\n\n'
          '    ${Pymd.elevatedCommand('mounter auto-mount')}\n\n'
          'If you just mounted it, restart `pymobiledevice3 remote tunneld` '
          'so the RSD service list is refreshed.\n\n'
          'Underlying error:\n$detail',
        );
      }
      throw TunnelError(
        'RSD tunnel ${tunnel.address}:${tunnel.port} is not reachable from '
        'this process:\n$detail',
      );
    }
  }

  static bool _deviceIsMissingDebugproxy(String detail) =>
      detail.contains('Services.') && detail.contains('missing') ||
      detail.contains('Developer Disk Image not mounted');
}
