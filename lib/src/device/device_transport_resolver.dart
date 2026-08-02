import 'dart:io' show Platform;

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/device_transport.dart';
import 'package:xcross/src/device/kernel_tunnel_transport.dart';
import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/device/tunnel_daemon.dart';
import 'package:xcross/src/device/tunnel_discovery.dart';
import 'package:xcross/src/device/userspace_tunnel_transport.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Which [DeviceTransport] to build.
enum DeviceTransportMode {
  /// Prefer the kernel tunnel, fall back to the userspace tunnel.
  auto,

  /// Kernel tunnel only; fail instead of falling back.
  kernel,

  /// Userspace tunnel only; never touch tunneld or a TUN device.
  userspace,
}

/// Builds the [DeviceTransport] for a session.
///
/// The kernel tunnel is preferred because it is the faster path, but it depends
/// on host networking that xcross does not control: a VPN kill-switch or
/// firewall can block its subnet, and creating it needs root/Administrator.
/// When it turns out to be unusable, the userspace tunnel takes over instead of
/// failing the run — it only needs usbmux and loopback.
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
        } on XcrossError catch (error) {
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

  /// tunneld + RSD discovery + a real debugproxy lookup.
  ///
  /// The lookup doubles as the reachability probe: it is the first traffic that
  /// actually crosses the tunnel, so a blocked subnet surfaces here rather than
  /// mid-session.
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
      // Never leak a daemon this attempt started; a tunneld the user runs
      // themselves is untouched by stop().
      daemon.stop();
      rethrow;
    }
  }

  static Future<int> _debugproxyPort(Tunnel tunnel) async {
    try {
      return await Pymd.rsdServicePort(
        rsdHost: tunnel.address,
        rsdPort: tunnel.port,
        service: DeviceConstants.debugproxyService,
      );
    } on XcrossError catch (error) {
      final detail = error.message;
      if (_deviceIsMissingDebugproxy(detail)) {
        throw XcrossError(
          "Developer Disk Image not mounted — the device doesn't expose the "
          'debugproxy service. Mount it and retry:\n\n'
          '    xcross prepare\n\n'
          'Or manually:\n\n'
          '    ${Pymd.elevatedCommand('mounter auto-mount')}\n\n'
          'If you just mounted it, restart `pymobiledevice3 remote tunneld` '
          'so the RSD service list is refreshed.\n\n'
          'Underlying error:\n$detail',
        );
      }
      throw XcrossError(
        'RSD tunnel ${tunnel.address}:${tunnel.port} is not reachable from '
        'this process:\n$detail',
      );
    }
  }

  /// True when RSD answered but carries no debugproxy service — a DDI problem
  /// that no transport can work around.
  static bool _deviceIsMissingDebugproxy(String detail) =>
      detail.contains('Services.') && detail.contains('missing') ||
      detail.contains('Developer Disk Image not mounted');
}
