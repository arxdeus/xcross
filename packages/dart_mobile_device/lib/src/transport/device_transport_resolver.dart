import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/constants.dart';
import 'package:dart_mobile_device/src/device_prepare.dart';
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

  /// Set [allowTunnelRepair] to false for best-effort callers: repairing the
  /// tunnel mounts the Developer Disk Image and starts a lockdown tunnel,
  /// which is minutes of work and a sudo prompt that only a real session has
  /// earned the right to spend.
  static Future<DeviceTransport> resolve({
    required String udid,
    Duration discoveryTimeout = const Duration(seconds: 60),
    bool allowTunnelRepair = true,
  }) async {
    final mode = _modeFromEnvironment();
    switch (mode) {
      case DeviceTransportMode.userspace:
        return UserspaceTunnelTransport(udid: udid);
      case DeviceTransportMode.kernel:
        return _kernelTransport(
          udid: udid,
          discoveryTimeout: discoveryTimeout,
          allowTunnelRepair: allowTunnelRepair,
        );
      case DeviceTransportMode.auto:
        try {
          return await _kernelTransport(
            udid: udid,
            discoveryTimeout: discoveryTimeout,
            allowTunnelRepair: allowTunnelRepair,
          );
        } on TunnelError catch (error) {
          if (_deviceIsMissingDebugproxy(error.message)) rethrow;
          // The reason belongs on screen, not behind --verbose: the userspace
          // tunnel cannot always carry hot reload, and a user who never sees
          // why is left with an app that runs and keys that do nothing.
          Log.logWarn(
            error is TunnelPrivilegeError
                ? 'no Administrator rights for the kernel RSD tunnel — '
                      'continuing over the userspace tunnel '
                      '(usbmux + loopback).\n'
                      'For the kernel tunnel, run `xcross tunnel` once from an '
                      'elevated terminal.'
                : 'kernel RSD tunnel unusable — continuing over the userspace '
                      'tunnel (usbmux + loopback):\n'
                      '${_firstLine(error.message)}',
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
    required bool allowTunnelRepair,
  }) async {
    final daemon = TunnelDaemon();
    try {
      await daemon.ensureRunning();
      final tunnel = await _discoverOrRepair(
        udid: udid,
        discoveryTimeout: discoveryTimeout,
        allowTunnelRepair: allowTunnelRepair,
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

  /// Discovery, retried once after repairing what tunneld could not do for
  /// itself.
  ///
  /// `xcross tunnel` is the documented prerequisite, but forgetting it used to
  /// cost a 60 s stall and a silently degraded session; every repair step is
  /// idempotent, so running them here is cheaper than the stall it replaces.
  static Future<Tunnel> _discoverOrRepair({
    required String udid,
    required Duration discoveryTimeout,
    required bool allowTunnelRepair,
  }) async {
    try {
      return await TunnelDiscovery.discoverTunnel(
        udid: udid,
        timeout: discoveryTimeout,
      );
    } on TunnelCreationError catch (error) {
      if (!allowTunnelRepair) rethrow;
      Log.logWarn(
        'tunneld has no RSD tunnel for this device — mounting the Developer '
        'Disk Image and starting one (what `xcross tunnel` does)',
      );
      Log.logTrace(error.message);
      try {
        await DevicePrepare.repairRsdTunnel();
      } on Object catch (repairFailure) {
        // Report what tunneld refused to do, not how the repair went: the
        // repair is an extra chance, never the thing the user asked for.
        Log.logTrace('tunnel repair failed: $repairFailure');
        throw error;
      }
      return TunnelDiscovery.discoverTunnel(
        udid: udid,
        timeout: discoveryTimeout,
      );
    }
  }

  static String _firstLine(String message) => message
      .split('\n')
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => message);

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
