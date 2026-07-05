// Ported from Sources/XToolSupport/CoreDeviceLauncher.swift
import 'dart:async';
import 'dart:io';

import 'package:xcross/src/constants/device_constants.dart';
import 'package:xcross/src/device/dart_vm_service_client.dart';
import 'package:xcross/src/device/gdb_remote_client.dart';
import 'package:xcross/src/device/hot_reload_controller.dart'
    show HotReloadController;
import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/device/tunnel_daemon.dart';
import 'package:xcross/src/device/tunneld.dart';
import 'package:xcross/src/models/device/hot_reload_config.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Launches an installed app on an iOS 17+ device through a CoreDevice RSD
/// tunnel. Blocks until the app exits or the user presses `q`/Ctrl-C.
///
/// CoreDeviceLauncher.swift:23
abstract final class CoreDeviceLauncher {
  // ── Entry point ───────────────────────────────────────────────────────────

  /// CoreDeviceLauncher.swift:80
  static Future<void> launch({
    required String udid,
    required String bundleId,
    required bool keepAttached,
    required bool checkedMode,
    List<String> arguments = const [],
    HotReloadConfig? hotReload,
  }) async {
    // 0. Ensure pymobiledevice3 is available. CoreDeviceLauncher.swift:88
    final pymdOk = await Pymd.ensureInstalled();
    if (!pymdOk) {
      throw XcrossError(
        'pymobiledevice3 is required for iOS 17+ but could not be installed automatically.',
      );
    }

    // 1. Ensure RSD tunnel daemon. CoreDeviceLauncher.swift:119
    final tunnelDaemon = TunnelDaemon();
    try {
      await tunnelDaemon.ensureRunning();
    } catch (e) {
      throw XcrossError('Failed to start tunneld: $e');
    }

    // 2. Discover tunnel endpoint. CoreDeviceLauncher.swift:127
    final tunnel = await Tunneld.discoverTunnel(udid: udid);
    logStatus('[xtool] connecting to RSD at ${tunnel.address}:${tunnel.port}');

    // 3. Resolve team-prefixed bundle id. CoreDeviceLauncher.swift:132
    final resolvedBundleId = await _resolveBundleId(bundleId);

    // 4. Resolve debugproxy port. CoreDeviceLauncher.swift:138
    final debugproxyPort = await _resolveDebugproxyPort(tunnel);

    // 5. Compose launch args. CoreDeviceLauncher.swift:150
    final appArgs = _buildAppArgs(
      arguments: arguments,
      checkedMode: checkedMode,
      hotReload: hotReload,
    );

    // 6. Launch suspended via DVT ProcessControl. CoreDeviceLauncher.swift:168
    final pid = await _launchSuspended(
        tunnel: tunnel, bundleId: resolvedBundleId, appArgs: appArgs);

    // 7. GDB-remote attach. CoreDeviceLauncher.swift:186
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

    // AOT / release: don't need to hold the connection. CoreDeviceLauncher.swift:198
    if (!keepAttached) {
      await gdb.close();
      tunnelDaemon.stop();
      return;
    }

    // 8. Optional hot reload setup. CoreDeviceLauncher.swift:206
    final hotReloadController = await _trySpinUpHotReload(
      hotReload: hotReload,
      tunnelAddress: tunnel.address,
    );

    // 9. Run keypress + drain loop. CoreDeviceLauncher.swift:229
    await _runSession(gdb: gdb, hotReload: hotReloadController);

    // Cleanup. CoreDeviceLauncher.swift:235
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
      final tunnel = await Tunneld.discoverTunnel(udid: udid);
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

  // ── Launch helpers ────────────────────────────────────────────────────────

  /// Resolve team-prefixed bundle id from the installed-app list.
  /// Returns [bundleId] unchanged on failure. CoreDeviceLauncher.swift:132
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

  /// Look up the debugproxy port via RSD info. CoreDeviceLauncher.swift:138
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
        '    sudo pymobiledevice3 mounter auto-mount\n\n'
        'If you just mounted it, restart `pymobiledevice3 remote tunneld` '
        'so the RSD service list is refreshed.',
      );
    }
  }

  /// Build the launch-argument list, prepending VM Service and checked-mode
  /// flags as required. CoreDeviceLauncher.swift:150
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
      // CoreDeviceLauncher.swift:160
      args.insertAll(0, [
        '--vm-service-host=::',
        '--vm-service-port=${DeviceConstants.vmServicePort}',
        '--disable-service-auth-codes',
      ]);
    }
    return args;
  }

  /// Launch the app suspended and return its device PID. CoreDeviceLauncher.swift:168
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
  /// on failure. CoreDeviceLauncher.swift:206
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

  // ── Session loop ──────────────────────────────────────────────────────────
  // CoreDeviceLauncher.swift:243

  static Future<void> _runSession({
    required GdbRemoteClient gdb,
    required HotReloadController? hotReload,
  }) async {
    var stopped = false;

    // Forward Ctrl-C cleanly; a second Ctrl-C hard-kills in case cleanup hangs.
    // CoreDeviceLauncher.swift:249
    ProcessSignal.sigint.watch().listen((_) {
      if (stopped) exit(130);
      stopped = true;
    });

    // Drain GDB-remote replies (stdout + exit notifications). CoreDeviceLauncher.swift:257
    final drainFuture = _drainGdbReplies(
        gdb: gdb, isStopped: () => stopped, setStopped: () => stopped = true);

    // Keypress loop. CoreDeviceLauncher.swift:274
    final keypressFuture = _runKeypressLoop(
      hotReload: hotReload,
      isStopped: () => stopped,
      requestStop: () => stopped = true,
    );

    while (!stopped) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await drainFuture.timeout(const Duration(seconds: 2), onTimeout: () {});
    await keypressFuture.timeout(const Duration(seconds: 1), onTimeout: () {});
  }

  /// Forward `O` (stdout) packets and stop on exit/termination.
  /// CoreDeviceLauncher.swift:257
  static Future<void> _drainGdbReplies({
    required GdbRemoteClient gdb,
    required bool Function() isStopped,
    required void Function() setStopped,
  }) async {
    await for (final reply in gdb.replies) {
      if (isStopped()) break;
      switch (reply.type) {
        case GdbReply.stdout:
          stdout.add(reply.stdoutBytes);
        case GdbReply.exited || GdbReply.terminated:
          logStatus('[xtool] app exited (${reply.payload})');
          setStopped();
          return;
        case GdbReply.stopped || GdbReply.other:
          break;
      }
    }
  }

  // CoreDeviceLauncher.swift:285
  static Future<void> _runKeypressLoop({
    required HotReloadController? hotReload,
    required bool Function() isStopped,
    required void Function() requestStop,
  }) async {
    // Only run if stdin is a TTY. CoreDeviceLauncher.swift:291
    if (!stdin.hasTerminal) return;

    try {
      stdin
        ..echoMode = false
        ..lineMode = false;
    } catch (_) {}

    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    // prevents overlapping reload/restart
    var busy = false;
    final sub = stdin.listen(
      (bytes) async {
        await _handleKeyByte(
          bytes: bytes,
          hotReload: hotReload,
          isStopped: isStopped,
          requestStop: requestStop,
          finish: finish,
          getBusy: () => busy,
          markBusy: () => busy = true,
          clearBusy: () => busy = false,
        );
      },
      onDone: finish,
      onError: (_) => finish(),
    );

    // Break out promptly when stopped externally (e.g. SIGINT), since the stdin
    // subscription otherwise keeps the event loop alive and blocks exit.
    final poll = Timer.periodic(const Duration(milliseconds: 150), (t) {
      if (isStopped()) {
        t.cancel();
        finish();
      }
    });

    await done.future;
    poll.cancel();
    await sub.cancel();
    try {
      stdin
        ..echoMode = true
        ..lineMode = true;
    } catch (_) {}
  }

  /// Handle a single raw [bytes] chunk from stdin inside [_runKeypressLoop].
  /// Quit keys set stopped and complete [finish]; reload/restart keys are
  /// dispatched only when [getBusy] returns false (no op in flight).
  static Future<void> _handleKeyByte({
    required List<int> bytes,
    required HotReloadController? hotReload,
    required bool Function() isStopped,
    required void Function() requestStop,
    required void Function() finish,
    required bool Function() getBusy,
    required void Function() markBusy,
    required void Function() clearBusy,
  }) async {
    if (isStopped()) {
      return finish();
    }
    final ch = bytes.isNotEmpty ? bytes[0] : 0;
    if (ch == DeviceConstants.keyQ ||
        ch == DeviceConstants.keyCtrlC ||
        ch == DeviceConstants.keyCtrlD) {
      requestStop();
      return finish();
    }
    // Ignore reload/restart keys while one is already in flight so presses
    // don't overlap and corrupt frontend_server state.
    if (getBusy()) return;
    if (ch == DeviceConstants.keyR) {
      markBusy();
      await _handleHotReload(hotReload);
      clearBusy();
    } else if (ch == DeviceConstants.keyBigR) {
      markBusy();
      await _handleHotRestart(hotReload);
      clearBusy();
    }
  }

  static Future<void> _handleHotReload(HotReloadController? hotReload) async {
    if (hotReload == null) return;
    logStatus('[xtool] hot reload…');
    try {
      final ok = await hotReload.reload();
      logStatus(ok
          ? '[xtool] reloaded ✓'
          : "[xtool] reload rejected (try 'R' to restart)");
    } catch (e) {
      logError('reload failed: $e');
    }
  }

  static Future<void> _handleHotRestart(HotReloadController? hotReload) async {
    if (hotReload == null) return;
    logStatus('[xtool] hot restart…');
    try {
      await hotReload.restart();
      logStatus('[xtool] restarted ✓');
    } catch (e) {
      logError('restart failed: $e');
    }
  }

  // ── Hot-reload bootstrap ──────────────────────────────────────────────────
  // CoreDeviceLauncher.swift:336

  static Future<HotReloadController> _spinUpHotReload({
    required HotReloadConfig config,
    required String tunnelAddress,
    required int vmServicePort,
  }) async {
    final hostPart =
        tunnelAddress.contains(':') ? '[$tunnelAddress]' : tunnelAddress;
    final wsUri = Uri.parse('ws://$hostPart:$vmServicePort/ws');

    final vm = await _waitForVmService(wsUri);

    // Spin up frontend_server + initial devFS upload. CoreDeviceLauncher.swift:365
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
  /// CoreDeviceLauncher.swift:349
  static Future<DartVmServiceClient> _waitForVmService(Uri wsUri) async {
    final vm = DartVmServiceClient();
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    dynamic lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        await vm.connect(wsUri, timeout: const Duration(seconds: 5));
        return vm;
      } on Object catch (e) {
        lastError = e;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }
    // ignore: only_throw_errors
    if (lastError case final Object error?) throw error;
    throw XcrossError('VM Service did not become available');
  }

  // ── Bundle ID resolution ──────────────────────────────────────────────────
  // CoreDeviceLauncher.swift:387

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
    final matches = ids
        .where((id) => id == base || id.endsWith(suffix))
        .toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    return matches.isNotEmpty ? matches.first : requested;
  }
}
