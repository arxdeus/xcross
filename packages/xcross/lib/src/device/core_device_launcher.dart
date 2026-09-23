import 'dart:async';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:meta/meta.dart';
import 'package:pure/pure.dart';
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/device_log.dart';
import 'package:xcross/src/device/session_console.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/flutter.dart';

const _cleanupTimeout = Duration(seconds: 2);
const _transportCloseTimeout = Duration(seconds: 3);
const _vmServiceConnectTimeout = Duration(seconds: 5);
const _vmServiceWaitTimeout = Duration(seconds: 60);
const _vmServicePollInterval = Duration(milliseconds: 800);

/// Shorter than the full discovery budget: [CoreDeviceLauncher
/// .terminateIfRunning] is best-effort and must not burn 60 s before an
/// install when tunneld has no device yet (common on first run / flaky
/// usbipd).
const _terminateDiscoveryTimeout = Duration(seconds: 8);

/// Launches an installed app on an iOS 17+ device through a CoreDevice RSD
/// tunnel. Blocks until the app exits or the user presses `q`/Ctrl-C.
abstract final class CoreDeviceLauncher {
  static bool get _isDap => Platform.environment['XCROSS_DAP'] == '1';

  /// [bundleId] must be the id the app is actually installed under — the
  /// value returned by `DeviceBackend.install`. Nothing here guesses it.
  static Future<void> launch({
    required String udid,
    required String bundleId,
    required CoreDeviceLaunchProfile profile,
    Future<bool> Function()? onRestartRequested,
  }) async {
    if (!await Pymd.ensureInstalled()) {
      throw XcrossError(
        'pymobiledevice3 is required for iOS 17+ but could not be '
        'installed automatically.',
      );
    }

    final transport = await DeviceTransportResolver.resolve(udid: udid);
    Log.logTrace('device transport: ${transport.description}');
    try {
      await _runSession(
        transport: transport,
        udid: udid,
        bundleId: bundleId,
        arguments: profile.argumentsForLaunch(
          isDap: _isDap,
          ipv6VmService: transport is KernelTunnelTransport,
        ),
        hotReload: profile.hotReload,
        onRestartRequested: onRestartRequested,
      );
    } finally {
      try {
        await transport.close().timeout(_transportCloseTimeout);
      } on Object catch (e) {
        Log.logTrace('cleanup transport: $e');
      }
    }
  }

  /// Best-effort: if [bundleId] is already running on the device, terminate it
  /// so a fresh install/launch doesn't collide with a live instance. Reuses the
  /// RSD tunnel (started here is left running for the subsequent launch). Never
  /// throws — logs and returns on any failure (e.g. no tunnel, app not
  /// running).
  static Future<void> terminateIfRunning({
    required String udid,
    required String bundleId,
  }) async {
    try {
      if (!await Pymd.ensureInstalled()) return;
      final transport = await DeviceTransportResolver.resolve(
        udid: udid,
        discoveryTimeout: _terminateDiscoveryTimeout,
        // Best-effort cleanup: never mount a DDI or start a tunnel for it.
        // The launch that follows does that, with the budget for it.
        allowTunnelRepair: false,
      );
      try {
        final pid = await Pymd.processIdForBundleId(
          deviceArgs: transport.pymdDeviceArgs,
          bundleId: await _resolveBundleId(bundleId, transport: transport),
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
      // A not-yet-mounted Developer Disk Image is the normal state here on a
      // fresh (especially wireless) boot: the launch that follows mounts it
      // with a proper budget. Its long "run xcross tunnel" message would be
      // pure noise for a condition this method expects.
      if ('$e'.contains('Developer Disk Image not mounted')) {
        Log.logTrace('skipping pre-install terminate: DDI not mounted yet');
        return;
      }
      Log.logWarn('could not check/terminate running app: $e');
    }
  }

  /// Launch, attach, and hold the interactive session open.
  static Future<void> _runSession({
    required DeviceTransport transport,
    required String udid,
    required String bundleId,
    required List<String> arguments,
    required HotReloadConfig? hotReload,
    Future<bool> Function()? onRestartRequested,
  }) async {
    final debugproxy = await transport.debugproxyEndpoint();

    final pid = await _launchSuspended(
      transport: transport,
      bundleId: bundleId,
      appArgs: arguments,
    );
    // Always on, verbose or not: a native abort (uncaught NSException,
    // misconfigured Firebase, failed plugin assertion) prints its reason to
    // the device log and nowhere else. Without it the session could only say
    // "App crashed: SIGABRT", which tells the user nothing actionable.
    final deviceLog = await DeviceLog.start(
      pid: pid,
      udid: udid,
      verbose: Log.isVerbose,
    );

    try {
      final gdb = await _attachDebugger(endpoint: debugproxy, pid: pid);

      ({HotReloadController? controller, String? unavailable}) hotReloadSetup =
          (controller: null, unavailable: null);
      HotReloadController? hotReloadController;
      PortForwarder? vmService;
      // Hot-reload setup is inside the same cleanup boundary as the session. A
      // failed VM connection must not leak the attached debugger or leave a DAP
      // launch paused forever.
      final console = SessionConsole(
        gdb: gdb,
        hotReload: null,
        hotReloadUnavailable: hotReload == null
            ? null
            : 'hot reload is still preparing; wait for "Hot reload ready".',
        onRestartRequested: onRestartRequested,
        crashReason: () => deviceLog?.crashReason,
        recentDeviceLines: () => deviceLog?.tailLines ?? const [],
      );
      final consoleFuture = console.run();
      try {
        // Attach leaves the app paused. Install the reply listener before
        // resuming it: debugproxy may send its first nonfatal stop packet
        // immediately after `c`, and a broadcast stream would otherwise lose
        // that packet and leave the Debug engine paused forever.
        await resumeInitialDebugger(
          console: console,
          consoleFuture: consoleFuture,
          resume: gdb.resume,
        );
        Log.logDone('Debugger attached');
        if (hotReload != null) Log.logInfo('Preparing hot reload…');
        final setupFuture = _trySpinUpHotReload(
          hotReload: hotReload,
          transport: transport,
          onVmServiceReady: () async {
            final forwarder = await _publishVmService(transport: transport);
            if (console.isStopped) {
              await forwarder?.close();
              throw XcrossError('Session stopped');
            }
            vmService = forwarder;
          },
        );
        final setupOrStop = await Future.any([
          setupFuture
              .then<({HotReloadController? controller, String? unavailable})?>(
                (setup) => setup,
              ),
          console.stopped
              .then<({HotReloadController? controller, String? unavailable})?>(
                (_) => null,
              ),
        ]);
        if (setupOrStop != null) {
          hotReloadSetup = setupOrStop;
          hotReloadController = hotReloadSetup.controller;
          console.configureHotReload(
            controller: hotReloadController,
            unavailable: hotReloadSetup.unavailable,
          );
        } else {
          unawaited(
            setupFuture
                .then((setup) => setup.controller?.close())
                .catchError((Object _) {}),
          );
        }
        await consoleFuture;
      } finally {
        console.stop();
        await _cleanupStep('console', () => consoleFuture);
        // Every step is timed out: a single hung flush/close on Windows left
        // `q` in a silent stuck state (no further input or output).
        await _cleanupStep('vm-service', () => vmService?.close());
        await _cleanupStep('hot-reload', () => hotReloadController?.close());
        await _cleanupStep('gdb-kill', gdb.kill);
        await _cleanupStep('gdb-close', gdb.close);
      }
    } finally {
      await deviceLog?.close();
    }
  }

  /// Do not leave the console's GDB subscription and SIGINT listener alive
  /// when the first resume fails before the ordinary session await.
  @visibleForTesting
  static Future<void> resumeInitialDebugger({
    required SessionConsole console,
    required Future<void> consoleFuture,
    required Future<void> Function() resume,
  }) async {
    try {
      await resume();
    } on Object catch (error, stack) {
      console.stop();
      try {
        await consoleFuture;
      } on Object {
        // A cleanup failure must not hide the original resume failure.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Connect and attach while the app is stopped. The caller installs its GDB
  /// reply listener before it resumes the process, so no initial stop packet
  /// can be lost between `c` and subscription.
  static Future<GdbRemoteClient> _attachDebugger({
    required DeviceEndpoint endpoint,
    required int pid,
  }) async {
    final gdb = GdbRemoteClient(host: endpoint.host, port: endpoint.port);
    try {
      await gdb.connect();
      await gdb.start();
      await gdb.attach(pid);
    } catch (e) {
      await gdb.close();
      throw XcrossError('Debugger attach failed: $e');
    }
    return gdb;
  }

  static Future<void> _cleanupStep(
    String label,
    Future<void>? Function() body,
  ) async {
    try {
      final future = body();
      if (future == null) return;
      await future.timeout(_cleanupTimeout);
    } on Object catch (e) {
      Log.logTrace('cleanup $label: $e');
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
        TunnelConstants.vmServicePort,
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

  /// Resolve the qualified bundle id from the installed-app list.
  ///
  /// Only [terminateIfRunning] needs this: it runs *before* install, so the
  /// signing identity (and with it the qualified id) is not known yet.
  /// Returns [bundleId] unchanged on failure.
  static Future<String> _resolveBundleId(
    String bundleId, {
    required DeviceTransport transport,
  }) async {
    String resolved;
    try {
      resolved = await _resolveInstalledBundleId(
        requested: bundleId,
        transport: transport,
      );
    } catch (_) {
      resolved = bundleId;
    }
    if (resolved != bundleId) {
      Log.logTrace('resolved installed bundle id: $bundleId -> $resolved');
    }
    return resolved;
  }

  static Future<String> _resolveInstalledBundleId({
    required String requested,
    required DeviceTransport transport,
  }) async {
    final ids = await Pymd.listInstalledApps(
      deviceArgs: transport.sideChannelDeviceArgs ?? const [],
    );
    return pickInstalledBundleId(installed: ids, requested: requested);
  }

  /// Pick the installed app that belongs to xcross.
  ///
  /// An `XCR-<identity>.<base>` entry always wins over a bare `<base>` one:
  /// the bare id is typically the user's App Store/TestFlight build, which is
  /// signed without `get-task-allow` and cannot be debugged (issue #26).
  /// Only when no qualified build is installed do we fall back to the exact
  /// requested id.
  @visibleForTesting
  static String pickInstalledBundleId({
    required List<String> installed,
    required String requested,
  }) {
    final base = ProvisioningIdentifiers.sanitize(requested);
    if (installed.contains(requested) &&
        requested.startsWith(ProvisioningIdentifiers.idPrefix)) {
      return requested;
    }
    // Shortest match wins: on a device carrying several team-prefixed builds
    // of the same app, the longest match resolves to the wrong one.
    final qualified =
        installed
            .where((id) => ProvisioningIdentifiers.isQualifiedForm(id, base))
            .toList()
          ..sort(compare((id) => id.length));
    // Several identities' builds of one app are indistinguishable by suffix,
    // and picking the wrong one launches a stale binary whose engine can be
    // a whole SDK behind — hot restart then fails with kernel-version
    // mismatches ("Could not run configuration in engine"). Run/install
    // callers avoid this by passing the exact installed id; anything else
    // (attach-style flows) at least gets told the guess was ambiguous.
    if (qualified.length > 1) {
      Log.logWarn(
        'several installed builds match "$requested": '
        '${qualified.join(', ')} — using ${qualified.first}. Delete the stale '
        'ones on the device if this picks wrong.',
      );
    }
    if (qualified.isNotEmpty) return qualified.first;
    return requested;
  }

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
      Log.logTrace('launch failure details: $e');
      throw XcrossError(launchFailureMessage(e));
    }
    Log.logTrace('launched suspended pid=$pid');
    return pid;
  }

  /// Explain the iOS foreground requirement without dumping pymobiledevice3's
  /// Python traceback into the normal CLI output.
  static String launchFailureMessage(Object error) {
    final details = error.toString();
    if (details.contains('Background launch requested')) {
      return 'Launch failed: iOS rejected a background launch. Unlock the '
          'iPhone, keep its screen awake, and run again.';
    }
    return 'Launch failed: $details';
  }

  /// Spin up hot reload if [hotReload] config is provided.
  ///
  /// Returns the reason alongside a null controller instead of swallowing it:
  /// the session stays alive without hot reload, and `r`/`R` have to be able
  /// to say why they do nothing.
  static Future<({HotReloadController? controller, String? unavailable})>
  _trySpinUpHotReload({
    required HotReloadConfig? hotReload,
    required DeviceTransport transport,
    Future<void> Function()? onVmServiceReady,
  }) async {
    if (hotReload == null) {
      Log.logInfo('Streaming app output ${Log.dim('— Ctrl-C to stop')}');
      return (
        controller: null,
        // Compose (Kotlin/Native, AOT) has no in-place reload at all, so the
        // Flutter-specific "frontend_server artifacts missing" wording would
        // be actively misleading there. The Compose path supplies its own
        // rebuild-and-restart handler instead, and never reaches this text.
        unavailable:
            'this session has no in-place reload: press Ctrl-C and run again '
            'after changing sources.',
      );
    }
    DartVmServiceClient? vm;
    HotReloadController? controller;
    try {
      final vmService = await transport.devicePortEndpoint(
        TunnelConstants.vmServicePort,
      );
      final wsUri = Uri.parse(
        'ws://${ProcessRunner.bracketHost(vmService.host)}:'
        '${vmService.port}/ws',
      );
      vm = await _waitForVmService(wsUri);
      await onVmServiceReady?.call();
      // A wireless session dies quietly when the phone locks, sleeps off the
      // network, or the tunnel drops. Without this, `r`/`R` just start
      // failing with opaque RPC errors while the console looks healthy.
      vm.onConnectionLost = () => Log.logWarn(
        'lost the connection to the app on the device — the phone locked, '
        'left the network, or the tunnel dropped. Hot reload is gone for '
        'this session: unlock the phone and run again.',
      );
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
        '${Log.dim('— r reload  ·  R restart  ·  q quit')}',
      );
      return (controller: controller, unavailable: null);
    } catch (e) {
      if (controller != null) {
        await controller.close();
      } else {
        await vm?.close();
      }
      if (_isDap) throw XcrossError('Hot reload setup failed: $e');
      Log.logWarn('hot reload unavailable: $e');
      return (
        controller: null,
        unavailable:
            'hot reload could not start over the ${transport.description}: '
            '$e\nRun `xcross tunnel`, then start the app again.',
      );
    }
  }

  /// Poll until the VM Service WebSocket is accepting connections.
  static Future<DartVmServiceClient> _waitForVmService(Uri wsUri) async {
    final vm = DartVmServiceClient();
    Object? lastError;
    final connected = await ProcessRunner.pollUntil<DartVmServiceClient>(
      timeout: _vmServiceWaitTimeout,
      interval: _vmServicePollInterval,
      attempt: () async {
        try {
          await vm.connect(wsUri, timeout: _vmServiceConnectTimeout);
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
}
