import 'dart:async';
import 'dart:io' show Platform;

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/dart_vm_service_client.dart';
import 'package:xcross/src/device/device_transport.dart';
import 'package:xcross/src/device/device_transport_resolver.dart';
import 'package:xcross/src/device/gdb_remote_client.dart';
import 'package:xcross/src/device/hot_reload_controller.dart'
    show HotReloadController;
import 'package:xcross/src/device/port_forwarder.dart';
import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/device/session_console.dart';
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

    final transport = await DeviceTransportResolver.resolve(udid: udid);
    Log.logTrace('device transport: ${transport.description}');
    try {
      await _runSession(
        transport: transport,
        bundleId: bundleId,
        arguments: arguments,
        hotReload: hotReload,
      );
    } finally {
      await transport.close();
    }
  }

  /// Launch, attach, and hold the interactive session open.
  static Future<void> _runSession({
    required DeviceTransport transport,
    required String bundleId,
    required List<String> arguments,
    required HotReloadConfig? hotReload,
  }) async {
    final resolvedBundleId = await _resolveBundleId(bundleId);
    final debugproxy = await transport.debugproxyEndpoint();
    final appArgs = _buildAppArgs(arguments: arguments, hotReload: hotReload);

    final pid = await _launchSuspended(
      transport: transport,
      bundleId: resolvedBundleId,
      appArgs: appArgs,
    );

    // ORDER MATTERS: connect -> start -> attach -> resume. The GDB client has a
    // single-slot exchange completer, so an RPC issued after resume() can be
    // hijacked by a stray stdout packet.
    final gdb = GdbRemoteClient(host: debugproxy.host, port: debugproxy.port);
    try {
      await gdb.connect();
      await gdb.start();
      await gdb.attach(pid);
      await gdb.resume();
      Log.logDone('Debugger attached');
    } catch (e) {
      await gdb.close();
      throw XcrossError('Debugger attach failed: $e');
    }

    HotReloadController? hotReloadController;
    PortForwarder? vmService;
    // Hot-reload setup is inside the same cleanup boundary as the session. A
    // failed VM connection must not leak the attached debugger or leave a DAP
    // launch paused forever.
    try {
      hotReloadController = await _trySpinUpHotReload(
        hotReload: hotReload,
        transport: transport,
      );
      if (hotReloadController != null) {
        vmService = await _publishVmService(transport: transport);
      }
      await SessionConsole(gdb: gdb, hotReload: hotReloadController).run();
    } finally {
      await vmService?.close();
      await hotReloadController?.close();
      await gdb.kill();
      await gdb.close();
    }
  }

  /// Forward the device's VM Service onto loopback and print the marker line
  /// the DAP watches for. Returns null (without the marker) if forwarding
  /// fails, since an unreachable URI is worse than none.
  static Future<PortForwarder?> _publishVmService({
    required DeviceTransport transport,
  }) async {
    try {
      final endpoint = await transport.devicePortEndpoint(
        DeviceConstants.vmServicePort,
      );
      final forwarder = await PortForwarder.start(
        deviceHost: endpoint.host,
        devicePort: endpoint.port,
      );
      Log.logInfo(
        DeviceConstants.vmServiceMarker,
        'ws://127.0.0.1:${forwarder.localPort}/ws',
      );
      return forwarder;
    } on Object catch (e) {
      if (_isDap) {
        throw XcrossError('Could not publish the VM Service: $e');
      }
      Log.logWarn('could not publish the VM Service on loopback: $e');
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
      // Best-effort only — don't burn the full 60s discovery before install
      // when tunneld has no device yet (common on first run / flaky usbipd).
      final transport = await DeviceTransportResolver.resolve(
        udid: udid,
        discoveryTimeout: const Duration(seconds: 8),
      );
      try {
        final resolved = await _resolveBundleId(bundleId);
        final pid = await Pymd.processIdForBundleId(
          deviceArgs: transport.pymdDeviceArgs,
          bundleId: resolved,
        );
        if (pid == null) return;
        Log.logTrace(
          'app already running (pid $pid); terminating before install…',
        );
        await Pymd.killPid(deviceArgs: transport.pymdDeviceArgs, pid: pid);
      } finally {
        await transport.close();
      }
    } on Object catch (e) {
      Log.logWarn('could not check/terminate running app: $e');
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
      Log.logTrace('resolved installed bundle id: $bundleId -> $resolved');
    }
    return resolved;
  }

  /// Build the launch-argument list, prepending VM Service and checked-mode
  /// flags as required.
  static List<String> _buildAppArgs({
    required List<String> arguments,
    required HotReloadConfig? hotReload,
  }) => [
    // VM Service must bind IPv6-any (::): the RSD tunnel is IPv6, and `::`
    // accepts IPv4-mapped peers too, so the usbmux relay path also reaches it.
    if (hotReload != null) ...[
      '--vm-service-host=::',
      '--vm-service-port=${DeviceConstants.vmServicePort}',
      '--disable-service-auth-codes',
    ],
    // DAP only: hold the root isolate at startup so the debug adapter can
    // register breakpoints before main() runs, then resume it — the flag
    // the reference Flutter adapter passes for the same reason. This is a
    // VM-level pause, separate from the GDB process resume above; the
    // interactive CLI has nothing that would resume it, so it stays off.
    if (hotReload != null && Platform.environment['XCROSS_DAP'] == '1')
      '--start-paused',
    '--enable-checked-mode', '--verify-entry-points', ...arguments,
  ];

  /// Launch the app suspended and return its device PID.
  static Future<int> _launchSuspended({
    required DeviceTransport transport,
    required String bundleId,
    required List<String> appArgs,
  }) async {
    final int pid;
    try {
      pid = await Pymd.launchSuspended(
        deviceArgs: transport.pymdDeviceArgs,
        bundleId: bundleId,
        appArguments: appArgs,
      );
    } catch (e) {
      throw XcrossError('Launch failed: $e');
    }
    Log.logTrace('launched suspended pid=$pid');
    return pid;
  }

  /// Spin up hot reload if [hotReload] config is provided; log and return null
  /// on failure.
  static bool get _isDap => Platform.environment['XCROSS_DAP'] == '1';

  static Future<HotReloadController?> _trySpinUpHotReload({
    required HotReloadConfig? hotReload,
    required DeviceTransport transport,
  }) async {
    if (hotReload == null) {
      Log.logInfo(
        'Streaming app output ${Log.ansi.subtle('— Ctrl-C to stop')}',
      );
      return null;
    }
    DartVmServiceClient? vm;
    HotReloadController? controller;
    try {
      final vmService = await transport.devicePortEndpoint(
        DeviceConstants.vmServicePort,
      );
      final wsUri = Uri.parse(
        'ws://${ProcessRunner.bracketHost(vmService.host)}:'
        '${vmService.port}/ws',
      );
      vm = await _waitForVmService(wsUri);
      // `print` and `log()` reach us only over these streams — the debugger
      // attached to an already-launched process, so it owns no stdio for the
      // app.
      await VmServiceOutput.forwardVmServiceOutput(vm);
      controller = HotReloadController(
        config: hotReload,
        vm: vm,
        vmService: vmService,
      );
      await controller.initialSync();
      Log.logInfo(
        'Hot reload ready '
        '${Log.ansi.subtle('— r reload  ·  R restart  ·  q quit')}',
      );
      return controller;
    } catch (e) {
      if (controller != null) {
        await controller.close();
      } else {
        await vm?.close();
      }
      if (_isDap) throw XcrossError('Hot reload setup failed: $e');
      Log.logWarn('hot reload unavailable: $e');
      return null;
    }
  }

  /// Poll until the VM Service WebSocket is accepting connections (up to 60 s).
  static Future<DartVmServiceClient> _waitForVmService(Uri wsUri) async {
    final vm = DartVmServiceClient();
    Object? lastError;
    final connected = await ProcessRunner.pollUntil<DartVmServiceClient>(
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
    await vm.close();
    // ignore: only_throw_errors
    if (lastError case final Object error?) throw error;
    throw XcrossError('VM Service did not become available');
  }

  static Future<String> _resolveInstalledBundleId({
    required String requested,
  }) async {
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
    final matches =
        ids.where((id) => id == base || id.endsWith(suffix)).toList()
          ..sort((a, b) => a.length.compareTo(b.length));
    return matches.isNotEmpty ? matches.first : requested;
  }
}
