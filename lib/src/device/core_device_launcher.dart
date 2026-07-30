import 'dart:async';

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/dart_vm_service_client.dart';
import 'package:xcross/src/device/gdb_remote_client.dart';
import 'package:xcross/src/device/hot_reload_controller.dart'
    show HotReloadController;
import 'package:xcross/src/device/port_forwarder.dart';
import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/device/session_console.dart';
import 'package:xcross/src/device/tunnel_daemon.dart';
import 'package:xcross/src/device/tunnel_discovery.dart';
import 'package:xcross/src/device/vm_service_output.dart';
import 'package:xcross/src/models/device/hot_reload_config.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Launches an installed app on an iOS 17+ device through a CoreDevice RSD
/// tunnel. Blocks until the app exits or the user presses `q`/Ctrl-C.
abstract final class CoreDeviceLauncher {
  static Future<void> launch({
    required String udid,
    required String bundleId,
    List<String> arguments = const [],
    HotReloadConfig? hotReload,
  }) async {
    if (!await Pymd.ensureInstalled()) {
      throw XcrossError(
        'pymobiledevice3 is required for iOS 17+ but could not be installed automatically.',
      );
    }

    final tunnelDaemon = TunnelDaemon();
    try {
      await tunnelDaemon.ensureRunning();
    } catch (e) {
      throw XcrossError('Failed to start tunneld: $e');
    }

    final tunnel = await TunnelDiscovery.discoverTunnel(udid: udid);
    logTrace('connecting to RSD at ${tunnel.address}:${tunnel.port}');

    final resolvedBundleId = await _resolveBundleId(bundleId);
    final debugproxyPort = await _resolveDebugproxyPort(tunnel);
    final appArgs = _buildAppArgs(
      arguments: arguments,
      hotReload: hotReload,
    );

    final pid = await _launchSuspended(
        tunnel: tunnel, bundleId: resolvedBundleId, appArgs: appArgs);

    // ORDER MATTERS: connect -> start -> attach -> resume. The GDB client has a
    // single-slot exchange completer, so an RPC issued after resume() can be
    // hijacked by a stray stdout packet.
    final gdb = GdbRemoteClient(host: tunnel.address, port: debugproxyPort);
    try {
      await gdb.connect();
      await gdb.start();
      await gdb.attach(pid);
      await gdb.resume();
      logDone('Debugger attached');
    } catch (e) {
      tunnelDaemon.stop();
      throw XcrossError('Debugger attach failed: $e');
    }

    final hotReloadController = await _trySpinUpHotReload(
      hotReload: hotReload,
      tunnelAddress: tunnel.address,
    );

    // Only advertised when hot reload is live: the VM Service flags are passed
    // to the app only when hotReload != null, so there is nothing to connect to
    // otherwise. Owned here rather than inside _trySpinUpHotReload because a
    // listening socket must be closed on the way out.
    final vmService = hotReloadController == null
        ? null
        : await _publishVmService(tunnelAddress: tunnel.address);

    // In a finally: the forwarder holds a LISTENING socket, which keeps the
    // Dart event loop alive. If the session throws (a gdb socket error when the
    // cable is pulled), skipping this cleanup hangs the process instead of
    // reporting the error.
    try {
      await SessionConsole(gdb: gdb, hotReload: hotReloadController).run();
    } finally {
      await vmService?.close();
      await hotReloadController?.close();
      await gdb.kill();
      await gdb.close();
      tunnelDaemon.stop();
    }
  }

  /// Forward the device's VM Service onto loopback and print the marker line
  /// the DAP watches for. Returns null (without the marker) if forwarding
  /// fails, since an unreachable URI is worse than none.
  static Future<PortForwarder?> _publishVmService({
    required String tunnelAddress,
  }) async {
    try {
      final forwarder = await PortForwarder.start(
        deviceHost: tunnelAddress,
        devicePort: DeviceConstants.vmServicePort,
      );
      logInfo(DeviceConstants.vmServiceMarker,
          'ws://127.0.0.1:${forwarder.localPort}/ws');
      return forwarder;
    } on Object catch (e) {
      logWarn('could not publish the VM Service on loopback: $e');
      return null;
    }
  }

  /// Best-effort: if [bundleId] is already running on the device, terminate it
  /// so a fresh install/launch doesn't collide with a live instance. Reuses the
  /// RSD tunnel (started here is left running for the subsequent launch). Never
  /// throws — logs and returns on any failure (e.g. no tunnel, app not running).
  static Future<void> terminateIfRunning({
    required String udid,
    required String bundleId,
  }) async {
    try {
      if (!await Pymd.ensureInstalled()) return;
      await TunnelDaemon().ensureRunning();
      // Best-effort only — don't burn the full 60s discovery before install
      // when tunneld has no device yet (common on first run / flaky usbipd).
      final tunnel = await TunnelDiscovery.discoverTunnel(
        udid: udid,
        timeout: const Duration(seconds: 8),
        pollInterval: const Duration(milliseconds: 800),
      );
      final resolved = await _resolveBundleId(bundleId);
      final pid = await Pymd.processIdForBundleId(
        rsdHost: tunnel.address,
        rsdPort: tunnel.port,
        bundleId: resolved,
      );
      if (pid == null) return;
      logTrace('app already running (pid $pid); terminating before install…');
      await Pymd.killPid(
          rsdHost: tunnel.address, rsdPort: tunnel.port, pid: pid);
    } on Object catch (e) {
      logWarn('could not check/terminate running app: $e');
    }
  }

  /// Resolve team-prefixed bundle id from the installed-app list.
  /// Returns [bundleId] unchanged on failure.
  static Future<String> _resolveBundleId(String bundleId) async {
    String resolved;
    try {
      resolved = await _resolveInstalledBundleId(requested: bundleId);
    } catch (_) {
      resolved = bundleId;
    }
    if (resolved != bundleId) {
      logTrace('resolved installed bundle id: $bundleId -> $resolved');
    }
    return resolved;
  }

  /// Look up the debugproxy port via RSD info.
  static Future<int> _resolveDebugproxyPort(Tunnel tunnel) async {
    try {
      return await Pymd.rsdServicePort(
        rsdHost: tunnel.address,
        rsdPort: tunnel.port,
        service: DeviceConstants.debugproxyService,
      );
    } catch (_) {
      throw XcrossError(
        "Developer Disk Image not mounted — the device doesn't expose the "
        'debugproxy service. Mount it and retry:\n\n'
        '    xcross prepare\n\n'
        'Or manually:\n\n'
        '    sudo pymobiledevice3 mounter auto-mount\n\n'
        'If you just mounted it, restart `pymobiledevice3 remote tunneld` '
        'so the RSD service list is refreshed.',
      );
    }
  }

  /// Build the launch-argument list, prepending VM Service and checked-mode
  /// flags as required.
  static List<String> _buildAppArgs({
    required List<String> arguments,
    required HotReloadConfig? hotReload,
  }) =>
      [
        // VM Service must bind IPv6-any (::) — the RSD tunnel is IPv6.
        if (hotReload != null) ...[
          '--vm-service-host=::',
          '--vm-service-port=${DeviceConstants.vmServicePort}',
          '--disable-service-auth-codes',
        ],
        '--enable-checked-mode', '--verify-entry-points', ...arguments,
      ];

  /// Launch the app suspended and return its device PID.
  static Future<int> _launchSuspended({
    required Tunnel tunnel,
    required String bundleId,
    required List<String> appArgs,
  }) async {
    final int pid;
    try {
      pid = await Pymd.launchSuspended(
        rsdHost: tunnel.address,
        rsdPort: tunnel.port,
        bundleId: bundleId,
        appArguments: appArgs,
      );
    } catch (e) {
      throw XcrossError('Launch failed: $e');
    }
    logTrace('launched suspended pid=$pid');
    return pid;
  }

  /// Spin up hot reload if [hotReload] config is provided; log and return null
  /// on failure.
  static Future<HotReloadController?> _trySpinUpHotReload({
    required HotReloadConfig? hotReload,
    required String tunnelAddress,
  }) async {
    if (hotReload == null) {
      logInfo('Streaming app output ${ansi.subtle('— Ctrl-C to stop')}');
      return null;
    }
    try {
      final controller = await _spinUpHotReload(
        config: hotReload,
        tunnelAddress: tunnelAddress,
        vmServicePort: DeviceConstants.vmServicePort,
      );
      logInfo('Hot reload ready '
          '${ansi.subtle('— r reload  ·  R restart  ·  q quit')}');
      return controller;
    } catch (e) {
      logWarn('hot reload unavailable: $e');
      return null;
    }
  }

  static Future<HotReloadController> _spinUpHotReload({
    required HotReloadConfig config,
    required String tunnelAddress,
    required int vmServicePort,
  }) async {
    final wsUri =
        Uri.parse('ws://${bracketHost(tunnelAddress)}:$vmServicePort/ws');
    final vm = await _waitForVmService(wsUri);
    // `print` and `log()` reach us only over these streams — the debugger
    // attached to an already-launched process, so it owns no stdio for the app.
    await forwardVmServiceOutput(vm);
    final controller = HotReloadController(
      config: config,
      vm: vm,
      tunnelAddress: tunnelAddress,
      vmServicePort: vmServicePort,
    );
    await controller.initialSync();
    return controller;
  }

  /// Poll until the VM Service WebSocket is accepting connections (up to 60 s).
  static Future<DartVmServiceClient> _waitForVmService(Uri wsUri) async {
    final vm = DartVmServiceClient();
    Object? lastError;
    final connected = await pollUntil<DartVmServiceClient>(
      timeout: const Duration(seconds: 60),
      interval: const Duration(milliseconds: 800),
      attempt: () async {
        try {
          await vm.connect(wsUri, timeout: const Duration(seconds: 5));
          return vm;
        } on Object catch (e) {
          lastError = e;
          rethrow;
        }
      },
    );
    if (connected != null) return connected;
    // ignore: only_throw_errors
    if (lastError case final Object error?) throw error;
    throw XcrossError('VM Service did not become available');
  }

  static Future<String> _resolveInstalledBundleId(
      {required String requested}) async {
    final ids = await Pymd.listInstalledApps();
    if (ids.contains(requested)) return requested;
    var base = requested;
    if (base.startsWith('XTL-')) {
      final dot = base.indexOf('.');
      if (dot >= 0) base = base.substring(dot + 1);
    }
    final suffix = '.$base';
    // Shortest suffix match wins: on a device carrying several team-prefixed
    // builds of the same app, the longest match resolves to the wrong one.
    final matches = ids
        .where((id) => id == base || id.endsWith(suffix))
        .toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    return matches.isNotEmpty ? matches.first : requested;
  }
}
