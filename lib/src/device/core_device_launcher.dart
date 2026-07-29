import 'dart:async';

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/dart_vm_service_client.dart';
import 'package:xcross/src/device/gdb_remote_client.dart';
import 'package:xcross/src/device/hot_reload_controller.dart'
    show HotReloadController;
import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/device/session_console.dart';
import 'package:xcross/src/device/tunnel_daemon.dart';
import 'package:xcross/src/device/tunnel_discovery.dart';
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
    required bool keepAttached,
    required bool checkedMode,
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
    logStatus('[xtool] connecting to RSD at ${tunnel.address}:${tunnel.port}');

    final resolvedBundleId = await _resolveBundleId(bundleId);
    final debugproxyPort = await _resolveDebugproxyPort(tunnel);
    final appArgs = _buildAppArgs(
      arguments: arguments,
      checkedMode: checkedMode,
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
      logStatus('[xtool] debugger attached; app running');
    } catch (e) {
      tunnelDaemon.stop();
      throw XcrossError('Debugger attach failed: $e');
    }

    // AOT / release: don't need to hold the connection.
    if (!keepAttached) {
      await gdb.close();
      tunnelDaemon.stop();
      return;
    }

    final hotReloadController = await _trySpinUpHotReload(
      hotReload: hotReload,
      tunnelAddress: tunnel.address,
    );

    await SessionConsole(gdb: gdb, hotReload: hotReloadController).run();

    await hotReloadController?.close();
    await gdb.kill();
    await gdb.close();
    tunnelDaemon.stop();
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
      logStatus(
          '[xtool] app already running (pid $pid); terminating before install…');
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
      logStatus('[xtool] resolved installed bundle id: $bundleId -> $resolved');
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
    required bool checkedMode,
    required HotReloadConfig? hotReload,
  }) {
    final args = List<String>.from(arguments);
    if (checkedMode) {
      args.insertAll(0, ['--enable-checked-mode', '--verify-entry-points']);
    }
    if (hotReload != null) {
      // VM Service must bind IPv6-any (::) — the RSD tunnel is IPv6.
      args.insertAll(0, [
        '--vm-service-host=::',
        '--vm-service-port=${DeviceConstants.vmServicePort}',
        '--disable-service-auth-codes',
      ]);
    }
    return args;
  }

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
    logStatus('[xtool] launched suspended pid=$pid');
    return pid;
  }

  /// Spin up hot reload if [hotReload] config is provided; log and return null
  /// on failure.
  static Future<HotReloadController?> _trySpinUpHotReload({
    required HotReloadConfig? hotReload,
    required String tunnelAddress,
  }) async {
    if (hotReload == null) {
      logStatus('[xtool] streaming app output (press Ctrl-C to stop)');
      return null;
    }
    try {
      final controller = await _spinUpHotReload(
        config: hotReload,
        tunnelAddress: tunnelAddress,
        vmServicePort: DeviceConstants.vmServicePort,
      );
      logStatus(
          "[xtool] hot reload ready ✓  (press 'r' to reload, 'R' to restart)");
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
