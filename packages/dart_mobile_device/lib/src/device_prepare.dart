import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/device.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:dart_mobile_device/src/pymd/pymd_devices.dart';
import 'package:dart_mobile_device/src/pymd/remote_pairing.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_daemon.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_discovery.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Bootstrap route selected by `xcross tunnel --wifi`.
enum WirelessBootstrapPath { usbLockdown, savedPairing, pairHost }

/// One-shot iOS 17+ host prep: mount the Developer Disk Image and start the
/// RSD tunnel(s) that [CoreDeviceLauncher] needs.
///
/// Equivalent to the manual:
/// ```sh
/// sudo pymobiledevice3 mounter auto-mount
/// sudo pymobiledevice3 lockdown start-tunnel
/// ```
/// plus ensuring `remote tunneld` is up (the REST discovery path used by
/// `xcross flutter run`).
abstract final class DevicePrepare {
  static final _tunnelReadyPattern = RegExp(
    'tunnel created|RSD Address|RSD Port',
    caseSensitive: false,
  );

  /// How long the wireless fallback waits for tunneld to build a tunnel once
  /// a pairing record exists (tunneld rescans mDNS every 5 s, then the
  /// RemotePairing handshake takes a few more).
  static const _wirelessTunnelTimeout = Duration(seconds: 45);

  static const _pollInterval = Duration(seconds: 2);

  /// Mount DDI, ensure tunneld, and start a lockdown RSD tunnel in the
  /// background. Leaves long-lived processes running after return.
  ///
  /// USB only: the wireless bring-up (pairing advertisement, Wi-Fi tunnel,
  /// tunnel-routed DDI mount) lives in [prepareWireless] behind an explicit
  /// `--wifi`, so the cable path stays simple and never blocks waiting for
  /// a phone that is not there.
  static Future<void> prepare() async {
    await _prepareSteps();
    Log.logDone(
      'Device ready '
      '${Log.dim('— DDI mounted, RSD tunnel up')}',
    );
    Log.logInfo('Next', Log.dim('xcross flutter run -u <UDID>'));
  }

  /// `xcross tunnel --wifi`: bring a wireless device up without a cable.
  ///
  /// Priority order:
  ///
  /// 1. USB phone: bootstrap RemotePairing through its trusted lockdown
  ///    connection and open the remote tunnel.
  /// 2. No USB, saved RemotePairing records: try those devices first, then
  ///    advertise a fresh `remote pair-host` if none reconnects.
  /// 3. No USB and no saved device: advertise `remote pair-host` immediately.
  ///
  /// Finally, mounts the DDI through the resulting RSD tunnel.
  static Future<void> prepareWireless() async {
    if (!await Pymd.ensureInstalled()) {
      throw TunnelError(
        'pymobiledevice3 is required but could not be installed automatically.',
      );
    }

    final usbDevice = await _firstUsbDevice();
    final savedPairings = RemotePairing.pairingRecordIds();
    final bootstrapSequence = wirelessBootstrapSequence(
      hasUsbDevice: usbDevice != null,
      hasSavedPairings: savedPairings.isNotEmpty,
    );
    if (bootstrapSequence.first == WirelessBootstrapPath.usbLockdown) {
      await _prepareWirelessOverUsb(usbDevice!);
      return;
    }

    // [TunnelDaemon.ensureRunning] requests elevation only when it actually
    // needs to start or replace the daemon. Reusing an already-reachable
    // tunneld must not prompt for sudo again.
    await TunnelDaemon().ensureRunning();

    var tunnel = await TunnelDiscovery.findExistingTunnel();
    if (tunnel == null &&
        bootstrapSequence.contains(WirelessBootstrapPath.savedPairing)) {
      Log.logInfo(
        'Wireless',
        'no USB device — reconnecting to ${savedPairings.length} saved '
            'wireless ${savedPairings.length == 1 ? 'device' : 'devices'}',
      );
      tunnel = await _awaitWirelessTunnel();
    }
    if (tunnel == null &&
        bootstrapSequence.contains(WirelessBootstrapPath.pairHost)) {
      final fresh = savedPairings.isNotEmpty;
      final name = fresh
          ? RemotePairing.freshAdvertiseName()
          : RemotePairing.advertiseName;
      if (fresh) {
        Log.logWarn(
          'saved wireless devices did not reconnect — starting fresh pairing',
        );
      }
      final pairHost = await RemotePairing.startPairHost(
        onLine: _onPairHostLine,
        fresh: fresh,
        name: name,
      );
      if (pairHost != null) {
        Log.logInfo(
          'Wireless',
          'to pair, on the iPhone (iOS 27+): Settings > Developer > Paired '
              'Macs > "Other Devices" > "$name" — the 6-digit code appears '
              'here when the phone connects',
        );
        Log.logInfo(
          'Wireless',
          'device-initiated pairing requires iOS 27+; on older iOS, connect '
              'the iPhone over USB once and rerun this command',
        );
        if (fresh) {
          Log.logInfo(
            'Wireless',
            'tap exactly "$name" under "Other Devices"; delete the older '
                '"${RemotePairing.advertiseName}" entry because its saved '
                'pairing no longer reconnects',
          );
        }
      }
      try {
        tunnel = await _awaitWirelessTunnel(pairHost: pairHost);
      } finally {
        pairHost?.kill();
      }
    }
    if (tunnel == null) {
      final guidance = savedPairings.isNotEmpty
          ? 'Saved pairing records were found, but none of those devices '
                'connected. Unlock the iPhone, keep its screen on, and verify '
                'it is on the same network.\nTo refresh the pairing, connect '
                'it over USB and rerun this command.'
          : 'No saved pairing exists. Device-initiated pairing requires '
                'iOS 27+: use Settings > Developer > Paired Macs > Other '
                'Devices. On older iOS, connect the iPhone over USB once and '
                'rerun this command.';
      throw TunnelError('No wireless device connected.\n$guidance');
    }
    await _autoMountOverRsd(tunnel);
    Log.logDone(
      'Device ready '
      '${Log.dim('— DDI mounted, wireless RSD tunnel up')}',
    );
    Log.logInfo('Next', Log.dim('xcross flutter run --wifi'));
  }

  /// USB always wins. Without it, saved records get the first attempt and a
  /// failed reconnect falls through to a fresh pair-host advertisement.
  @visibleForTesting
  static List<WirelessBootstrapPath> wirelessBootstrapSequence({
    required bool hasUsbDevice,
    required bool hasSavedPairings,
  }) {
    if (hasUsbDevice) return const [WirelessBootstrapPath.usbLockdown];
    if (hasSavedPairings) {
      return const [
        WirelessBootstrapPath.savedPairing,
        WirelessBootstrapPath.pairHost,
      ];
    }
    return const [WirelessBootstrapPath.pairHost];
  }

  /// First USB-attached phone, or null when usbmuxd is unavailable/no cable is
  /// attached. A missing usbmuxd is routine for the cable-free pairing path.
  static Future<Device?> _firstUsbDevice() async {
    try {
      final devices = await PymdDevices.devices(mode: DeviceSearchMode.usb);
      return devices.isEmpty ? null : devices.first;
    } on TunnelError catch (e) {
      Log.logTrace('USB probe before wireless pairing failed: ${e.message}');
      return null;
    }
  }

  /// Bootstrap RemotePairing over an already-trusted USB lockdown connection.
  ///
  /// `lockdown remotepairing --pair` uses the existing USB trust and writes the
  /// separate RemotePairing record consumed by tunneld, without the iOS 27+
  /// Paired Macs flow or a six-digit PIN. Do not run classic `lockdown pair`
  /// here: rewriting an existing usbmux pair record is rejected by some Linux
  /// usbmuxd versions with `BadDevError`. Enabling Wi-Fi connections keeps the
  /// device discoverable after unplug.
  static Future<void> _prepareWirelessOverUsb(Device device) async {
    Log.logInfo(
      'Wireless',
      '${device.name} found on USB — pairing wireless services over lockdown',
    );
    await Log.logStep(
      'Pairing wireless services over USB',
      () => Pymd.run(lockdownRemotePairArgs(device.udid)),
    );
    await Log.logStep(
      'Enabling Wi-Fi connections',
      () => Pymd.run(lockdownWifiArgs(device.udid)),
    );

    await TunnelDaemon().ensureRunning();
    final tunnel = await TunnelDiscovery.discoverTunnel(
      udid: device.udid,
      timeout: _wirelessTunnelTimeout,
      pollInterval: _pollInterval,
    );
    await _autoMountOverRsd(tunnel);
    Log.logDone(
      'Device ready '
      '${Log.dim('— paired over USB, wireless RSD tunnel up')}',
    );
    Log.logInfo('Next', Log.dim('unplug USB, then xcross flutter run --wifi'));
  }

  /// Arguments kept explicit and testable because wireless tunneld requires
  /// this RemotePairing-over-lockdown command, not classic `lockdown pair`.
  @visibleForTesting
  static List<String> lockdownRemotePairArgs(String udid) => [
    'lockdown',
    'remotepairing',
    '--pair',
    '--udid',
    udid,
  ];

  @visibleForTesting
  static List<String> lockdownWifiArgs(String udid) => [
    'lockdown',
    'wifi-connections',
    '--state',
    'on',
    '--udid',
    udid,
  ];

  /// Forward the advertisement's output: the lines the user must act on
  /// (the 6-digit code, the pairing result) interrupt whatever step is on
  /// screen; the boilerplate and 15 s heartbeat go to `--verbose` trace.
  ///
  /// One line gets special handling: upstream's "Pairing attempt from …
  /// failed" WARNING is the signature of a phone resuming an *old* pairing
  /// against this advertisement (which holds fresh keys every run) — the
  /// user must delete the entry on the phone, and without this hint the tap
  /// looks like it simply did nothing.
  static void _onPairHostLine(String line) {
    // Protocol lines from the bundled runner (see scripts/pair_host.py).
    if (line.startsWith('XCROSS-PAIR-')) {
      _onPairProtocolLine(line);
      return;
    }
    if (line.contains('Pairing attempt from')) {
      Log.logTrace('[pair-host] $line');
      if (!_warnedPairResumeFailure) {
        _warnedPairResumeFailure = true;
        Log.logWarn(
          'the iPhone tried to resume an old pairing with this host and '
          'failed. On the phone, delete "${RemotePairing.advertiseName}" '
          'under Settings > Developer > Paired Macs, then tap it under '
          '"Other Devices" to pair fresh (the 6-digit code appears here).',
        );
      }
      return;
    }
    const visible = [
      'Enter this code',
      'Paired with device',
      'Pairing record',
      // The phone reached us: acknowledge the tap immediately.
      'Device connected',
    ];
    if (visible.any(line.contains)) {
      Log.logStatus(line);
    } else {
      Log.logTrace('[pair-host] $line');
    }
  }

  static bool _warnedPairResumeFailure = false;

  /// Render the bundled runner's machine-readable protocol.
  static void _onPairProtocolLine(String line) {
    final rest = line.split(' ').skip(1).join(' ');
    switch (line.split(' ').first) {
      case 'XCROSS-PAIR-PIN':
        Log.stopStep();
        Log.logStatus('');
        Log.logStatus(
          '  Enter this code on the iPhone: '
          '${Log.ansi.bold}${Log.ansi.green}$rest${Log.ansi.none}',
        );
        Log.logStatus('');
      case 'XCROSS-PAIR-CONNECTED':
        Log.logStatus('${Glyph.info} the iPhone connected — pairing…');
      case 'XCROSS-PAIR-RETRY':
        Log.logTrace('[pair-host] attempt failed, still advertising: $rest');
      case 'XCROSS-PAIR-OK':
        Log.logDone('Paired with $rest');
      case 'XCROSS-PAIR-FAIL':
        Log.logTrace('[pair-host] failed: $rest');
      case 'XCROSS-PAIR-ADVERTISING':
        Log.logTrace('[pair-host] advertising $rest');
      case 'XCROSS-PAIR-WAITING':
        Log.logTrace('[pair-host] waiting ${rest}s');
      case 'XCROSS-PAIR-RECORD':
        Log.logTrace('[pair-host] record: $rest');
      default:
        Log.logTrace('[pair-host] $line');
    }
  }

  /// The same steps as [prepare], without the closing banner.
  ///
  /// Called mid-session when tunneld itself refused to create a tunnel: every
  /// step is idempotent, so a session that only lacks the Developer Disk Image
  /// or a lockdown tunnel repairs itself instead of silently degrading.
  static Future<void> repairRsdTunnel() => _prepareSteps();

  static Future<void> _prepareSteps() async {
    if (!await Pymd.ensureInstalled()) {
      throw TunnelError(
        'pymobiledevice3 is required but could not be installed automatically.',
      );
    }

    await HostPrivileges.ensureDeviceToolAccess(
      posixManualHint:
          'Start prepare steps manually:\n'
          '    ${Pymd.elevatedCommand('mounter auto-mount')}\n'
          '    ${Pymd.elevatedCommand('lockdown start-tunnel')}',
      windowsDeniedMessage:
          'xcross needs Administrator rights to create the Windows RSD tunnel.\n'
          'Open PowerShell with "Run as administrator", then run:\n'
          '    xcross tunnel',
    );

    // tunneld first: it needs no device and `_ensureLockdownTunnel` skips
    // itself when tunneld already carries a tunnel.
    await TunnelDaemon().ensureRunning();
    await _autoMount();
    await _ensureLockdownTunnel();
  }

  /// Wait for tunneld to have any RSD tunnel, while the pairing
  /// advertisement (when running) gives the user the chance to create the
  /// pairing it needs. Null when waiting is pointless or nothing appeared.
  static Future<Tunnel?> _awaitWirelessTunnel({Process? pairHost}) async {
    final hasRecord = RemotePairing.pairingRecordIds().isNotEmpty;
    if (pairHost == null && !hasRecord) return null;

    final step = Log.beginStep('Waiting for a wireless device');
    final diagnostics = _WirelessWaitDiagnostics(
      step: step,
      hasRecord: hasRecord,
    );
    try {
      if (pairHost != null) {
        // Phase 1: while the advertisement runs. Ends on pairing completion
        // (exit 0), advertisement timeout (non-zero), or a tunnel appearing
        // because the phone silently reconnected on the old record.
        var exitCode = -1;
        var exited = false;
        unawaited(
          pairHost.exitCode.then((code) {
            exitCode = code;
            exited = true;
          }),
        );
        final deadline = DateTime.now().add(RemotePairing.pairHostTimeout);
        while (!exited && DateTime.now().isBefore(deadline)) {
          final tunnel = await TunnelDiscovery.findExistingTunnel();
          if (tunnel != null) {
            step.done();
            return tunnel;
          }
          await diagnostics.tick();
          await Future<void>.delayed(_pollInterval);
        }
        if (exited && exitCode != 0 && !hasRecord) {
          step.fail();
          return null;
        }
      }
      // Phase 2: a pairing record exists (fresh or old) — give tunneld one
      // discovery cycle to find the phone and build the tunnel.
      final deadline = DateTime.now().add(_wirelessTunnelTimeout);
      while (DateTime.now().isBefore(deadline)) {
        final tunnel = await TunnelDiscovery.findExistingTunnel();
        if (tunnel != null) {
          step.done();
          return tunnel;
        }
        await diagnostics.tick();
        await Future<void>.delayed(_pollInterval);
      }
      step.fail();
      return null;
    } on Object {
      step.fail();
      rethrow;
    }
  }

  /// `pymobiledevice3 mounter auto-mount --rsd <host> <port>` — mounts the
  /// DDI through the RSD tunnel itself, the only route that reaches a
  /// wireless-only device. Needs no root.
  static Future<void> _autoMountOverRsd(Tunnel tunnel) => Log.logStep(
    'Mounting Developer Disk Image',
    () => Pymd.run([
      'mounter',
      'auto-mount',
      '--rsd',
      tunnel.address,
      '${tunnel.port}',
    ]),
  );

  /// `sudo pymobiledevice3 mounter auto-mount` (one-shot).
  static Future<void> _autoMount() async {
    final argv = await Pymd.elevatedArgs(['mounter', 'auto-mount']);
    Log.logTrace('[pymobiledevice3] mounting DDI: ${argv.join(' ')}');
    // Captured (not inheritStdio): a child writing to fd1 would shred the
    // spinner. Runs under `sudo -n`, so there is no prompt to hide.
    await Log.logStep('Mounting Developer Disk Image', () async {
      final result = await ProcessRunner.run(
        argv.first,
        argv.sublist(1),
        environment: Pymd.usbmuxEnvironment(),
      );
      Log.logTrace(result.stdout.trim());
      // auto-mount exits 0 even when it never reached the device (it just
      // logs "ERROR Device is not connected"), which otherwise shows a green
      // checkmark and defers the real failure to the tunnel step.
      final stderr = result.stderr.trim();
      if (result.exitCode != 0 || _isDeviceMissing(stderr)) {
        throw TunnelError(
          'mounter auto-mount failed (exit ${result.exitCode}).\n'
          '${explainTunnelExit(stderr.isEmpty ? const [] : stderr.split('\n'))}'
          'Retry manually:\n'
          '    ${Pymd.elevatedCommand('mounter auto-mount')}',
        );
      }
    });
  }

  /// Start `lockdown start-tunnel` in the background if one is not already
  /// producing an RSD tunnel. Leaves the process running after prepare exits.
  ///
  /// Skips when tunneld already exposes a tunnel: on Windows a second
  /// `lockdown start-tunnel` creates another WinTun adapter for the same
  /// device and breaks IPv6 RSD connectivity (connect → WinError 10013).
  static Future<void> _ensureLockdownTunnel() async {
    if (await _tunneldHasTunnel()) {
      Log.logTrace(
        'tunneld already has an RSD tunnel; skipping lockdown start-tunnel',
      );
      return;
    }
    if (await _lockdownTunnelLooksAlive()) {
      Log.logTrace('lockdown start-tunnel already running');
      return;
    }
    await Log.logStep('Starting lockdown RSD tunnel', _startLockdownTunnel);
  }

  /// True when the local tunneld REST API already lists at least one tunnel.
  static Future<bool> _tunneldHasTunnel() async =>
      await TunnelDiscovery.findExistingTunnel() != null;

  /// Spawn `lockdown start-tunnel` and wait for it to report an RSD tunnel.
  static Future<void> _startLockdownTunnel() async {
    final argv = await Pymd.elevatedArgs(['lockdown', 'start-tunnel']);
    final logPath = p.join(
      Directory.systemTemp.path,
      'xcross-start-tunnel.log',
    );
    final logFile = File(logPath);
    if (!logFile.existsSync()) logFile.createSync(recursive: true);

    Log.logTrace(
      '[pymobiledevice3] starting lockdown RSD tunnel'
      ' (background; log: $logPath): ${argv.join(' ')}',
    );

    late Process proc;
    try {
      // Piped (never inheritStdio): an inherited stdin steals `r`/`R`/`q` from
      // the hot-reload keypress loop for the whole session.
      proc = await Process.start(
        argv.first,
        argv.sublist(1),
        environment: Pymd.usbmuxEnvironment(),
      );
    } catch (e) {
      throw TunnelError('could not start lockdown start-tunnel: $e');
    }

    try {
      await proc.stdin.close();
    } catch (_) {}

    final logSink = logFile.openWrite(mode: FileMode.append);
    final ready = Completer<void>();

    // pymobiledevice3 reports real failures ("Device is not connected",
    // "Failed to connect to usbmuxd socket") on stderr and then exits 0, so
    // the exit code says nothing. Keep the last lines to explain *why* it
    // stopped instead of pointing at a log file the user has to open.
    final recent = <String>[];
    void onLine(String line) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) return;
      Log.logTrace(trimmed);
      recent.add(trimmed);
      if (recent.length > 5) recent.removeAt(0);
      if (!ready.isCompleted && _tunnelReadyPattern.hasMatch(trimmed)) {
        ready.complete();
      }
    }

    _teeOutput(proc, logSink, onLine);
    unawaited(
      proc.exitCode.then((code) async {
        try {
          await logSink.flush();
          await logSink.close();
        } catch (_) {}
        if (!ready.isCompleted) {
          ready.completeError(
            TunnelError(
              'lockdown start-tunnel exited early (code $code).\n'
              '${explainTunnelExit(recent)}'
              'See $logPath',
            ),
          );
        }
      }),
    );

    try {
      await ready.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw TunnelError(
        'lockdown start-tunnel did not report a tunnel within 60s.\n'
        'Keep the phone unlocked and trusted, then retry:\n'
        '    ${Pymd.elevatedCommand('lockdown start-tunnel')}\n'
        'See $logPath for output.',
      );
    } on TunnelError {
      rethrow;
    }

    Log.logTrace(
      '[pymobiledevice3] lockdown RSD tunnel is up '
      '(pid ${proc.pid}; leave it running)',
    );
  }

  /// Whether pymobiledevice3 output says the device vanished from usbmux.
  static bool _isDeviceMissing(String output) =>
      output.contains('Device is not connected') ||
      output.contains('Failed to connect to usbmuxd socket');

  /// Turn the daemon's last output lines into an actionable hint.
  @visibleForTesting
  static String explainTunnelExit(List<String> recent) {
    final detail = recent.join('\n');
    final buffer = StringBuffer();
    if (detail.isNotEmpty) buffer.writeln(detail);
    if (detail.contains('Device is not connected')) {
      buffer.writeln(
        'The device is no longer visible to usbmuxd. Unplug and replug the '
        'cable (or unlock and re-trust the phone), then retry.',
      );
    } else if (detail.contains('usbmuxd')) {
      buffer.writeln(
        'usbmuxd is not reachable. Start it with '
        '"sudo systemctl start usbmuxd", then retry.',
      );
    }
    return buffer.toString();
  }

  /// Tee the raw bytes of both output streams to [logSink], then decode a
  /// separate view of the same broadcast stream into lines for [onLine].
  static void _teeOutput(
    Process proc,
    IOSink logSink,
    void Function(String line) onLine,
  ) {
    for (final raw in [proc.stdout, proc.stderr]) {
      final stream = raw.asBroadcastStream();
      stream.listen(logSink.add, onError: (_) {});
      stream
          // Lossy on purpose: pymobiledevice3 can emit non-UTF-8 bytes, and a
          // strict decoder would drop the whole chunk — losing the ASCII
          // readiness line with it and stalling until the readiness timeout.
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine, onError: (_) {});
    }
  }

  /// Best-effort: a live `start-tunnel` child usually holds a tun interface
  /// and shows up in the process list.
  static Future<bool> _lockdownTunnelLooksAlive() async {
    if (Platform.isWindows) {
      return _windowsLockdownTunnelLooksAlive();
    }
    try {
      final result = await ProcessRunner.run('pgrep', [
        '-f',
        'pymobiledevice3.*lockdown.*start-tunnel',
      ]);
      return result.exitCode == 0 && result.stdout.trim().isNotEmpty;
    } on Object {
      return false;
    }
  }

  /// `pgrep` is unavailable on Windows; match elevated tunnel children via
  /// CIM instead. Command lines of other users' elevated processes may be
  /// blank — treat any `pymobiledevice3` image as "already running" only when
  /// tunneld already has a tunnel (handled by [_tunneldHasTunnel] first).
  static Future<bool> _windowsLockdownTunnelLooksAlive() async {
    try {
      final result = await ProcessRunner.run(
        await ProcessRunner.locateTool('powershell'),
        const [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r"Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'lockdown.*start-tunnel|start-tunnel' } | Select-Object -First 1 -ExpandProperty ProcessId",
        ],
      );
      return result.exitCode == 0 && result.stdout.trim().isNotEmpty;
    } on Object {
      return false;
    }
  }
}

/// Periodic "what is actually going on" reporting for the wireless wait.
///
/// The wait has three invisible states that all render as one spinner: the
/// phone is not on this network at all, the phone is here but not connecting
/// (locked, or its pairing was deleted), and the phone is mid-handshake. A
/// browse for `_remotepairing._tcp` every ~20 s tells the first two apart,
/// and the message updates once per state change — locked phones drop off
/// mDNS entirely, which is by far the most common reason this wait hangs.
final class _WirelessWaitDiagnostics {
  _WirelessWaitDiagnostics({required this.step, required this.hasRecord});

  static const _browseEvery = Duration(seconds: 20);

  final Step step;
  final bool hasRecord;
  DateTime _nextBrowse = DateTime.now();
  bool? _lastAdvertised;

  Future<void> tick() async {
    if (DateTime.now().isBefore(_nextBrowse)) return;
    _nextBrowse = DateTime.now().add(_browseEvery);
    final advertised = await PymdDevices.wirelessPairingAdvertised();
    if (advertised == _lastAdvertised) return;
    _lastAdvertised = advertised;
    if (!advertised) {
      step.log(
        'no iPhone is visible on this network — unlock the phone and keep '
        'its screen on (a locked iPhone leaves Wi-Fi), and check it is on '
        'this network',
      );
    } else if (hasRecord) {
      step.log(
        'iPhone visible on the network — waiting for it to connect '
        '(existing pairing: no code will be shown; give it ~30 s)',
      );
    } else {
      step.log(
        'iPhone visible on the network — pair it now: Settings > Developer '
        '> Paired Macs > "Other Devices"',
      );
    }
  }
}
