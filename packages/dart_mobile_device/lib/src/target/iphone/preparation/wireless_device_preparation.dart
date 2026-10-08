import 'dart:async';
import 'dart:io';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:dart_mobile_device/shared/device/models/device.dart';
import 'package:dart_mobile_device/shared/errors/errors.dart';
import 'package:dart_mobile_device/src/shared/device/models/tunnel.dart';
import 'package:dart_mobile_device/src/target/iphone/device/pymd/remote_pairing.dart';
import 'package:dart_mobile_device/src/target/iphone/device/tunnel/tunnel_daemon.dart';
import 'package:dart_mobile_device/src/target/iphone/device/tunnel/tunnel_discovery.dart';
import 'package:dart_mobile_device/src/target/iphone/preparation/developer_disk_image.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd_devices.dart';
import 'package:meta/meta.dart';

/// Bootstrap route selected by `xcross tunnel --wifi`.
@internal
enum WirelessBootstrapPath { usbLockdown, savedPairing, pairHost }

@internal
final class WirelessDevicePreparation {
  WirelessDevicePreparation(this.pymd, {required this.diskImage});

  final Pymd pymd;
  final DeveloperDiskImage diskImage;
  static const _wirelessTunnelTimeout = Duration(seconds: 45);
  static const _pollInterval = Duration(seconds: 2);

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
  Future<void> prepare() async {
    if (!await pymd.ensureInstalled()) {
      throw TunnelError(
        'pymobiledevice3 is required but could not be installed automatically.',
      );
    }

    final usbDevice = await _firstUsbDevice();
    final savedPairings = RemotePairing(pymd).pairingRecordIds();
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
    await TunnelDaemon(pymd).ensureRunning();

    var tunnel = await _findExistingTunnel();
    final shouldReconnectSaved = bootstrapSequence.contains(
      WirelessBootstrapPath.savedPairing,
    );
    if (tunnel == null && shouldReconnectSaved) {
      tunnel = await _reconnectSavedPairings(savedPairings);
    }
    final shouldAdvertisePairHost = bootstrapSequence.contains(
      WirelessBootstrapPath.pairHost,
    );
    if (tunnel == null && shouldAdvertisePairHost) {
      tunnel = await _pairOverPairHost(fresh: savedPairings.isNotEmpty);
    }
    if (tunnel == null) {
      throw _noWirelessDeviceError(hasSavedPairings: savedPairings.isNotEmpty);
    }
    await diskImage.mountOverRsd(tunnel);
    pymd.runner.log.logDone(
      'Device ready '
      '${pymd.runner.log.dim('— DDI mounted, wireless RSD tunnel up')}',
    );
    pymd.runner.log.logInfo(
      'Next',
      pymd.runner.log.dim('xcross flutter run --wifi'),
    );
  }

  Future<Tunnel?> _findExistingTunnel() => TunnelDiscovery(
    pymd.runner.log,
    localHttp: pymd.localHttp,
  ).findExistingTunnel();

  Future<Tunnel?> _reconnectSavedPairings(List<String> savedPairings) {
    final noun = savedPairings.length == 1 ? 'device' : 'devices';
    pymd.runner.log.logInfo(
      'Wireless',
      'no USB device — reconnecting to ${savedPairings.length} saved '
          'wireless $noun',
    );
    return _awaitWirelessTunnel();
  }

  Future<Tunnel?> _pairOverPairHost({required bool fresh}) async {
    final name = fresh
        ? RemotePairing(pymd).freshAdvertiseName()
        : RemotePairing(pymd).advertiseName;
    if (fresh) {
      pymd.runner.log.logWarn(
        'saved wireless devices did not reconnect — starting fresh pairing',
      );
    }
    final pairHost = await RemotePairing(
      pymd,
    ).startPairHost(onLine: _onPairHostLine, fresh: fresh, name: name);
    if (pairHost != null) _explainPairHost(name: name, fresh: fresh);
    try {
      final tunnel = await _awaitWirelessTunnel(pairHost: pairHost);
      return tunnel;
    } finally {
      if (pairHost != null) await pymd.runner.killTree(pairHost);
    }
  }

  void _explainPairHost({required String name, required bool fresh}) {
    pymd.runner.log.logInfo(
      'Wireless',
      'to pair, on the iPhone (iOS 27+): Settings > Developer > Paired '
          'Macs > "Other Devices" > "$name" — the 6-digit code appears '
          'here when the phone connects',
    );
    pymd.runner.log.logInfo(
      'Wireless',
      'device-initiated pairing requires iOS 27+; on older iOS, connect '
          'the iPhone over USB once and rerun this command',
    );
    if (fresh) {
      pymd.runner.log.logInfo(
        'Wireless',
        'tap exactly "$name" under "Other Devices"; delete the older '
            '"${RemotePairing(pymd).advertiseName}" entry because its saved '
            'pairing no longer reconnects',
      );
    }
  }

  TunnelError _noWirelessDeviceError({required bool hasSavedPairings}) {
    final guidance = hasSavedPairings
        ? 'Saved pairing records were found, but none of those devices '
              'connected. Unlock the iPhone, keep its screen on, and verify '
              'it is on the same network.\nTo refresh the pairing, connect '
              'it over USB and rerun this command.'
        : 'No saved pairing exists. Device-initiated pairing requires '
              'iOS 27+: use Settings > Developer > Paired Macs > Other '
              'Devices. On older iOS, connect the iPhone over USB once and '
              'rerun this command.';
    return TunnelError('No wireless device connected.\n$guidance');
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
  Future<Device?> _firstUsbDevice() async {
    try {
      final devices = await PymdDevices(
        pymd,
      ).devices(mode: DeviceSearchMode.usb);
      return devices.isEmpty ? null : devices.first;
    } on TunnelError catch (e) {
      pymd.runner.log.logTrace(
        'USB probe before wireless pairing failed: ${e.message}',
      );
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
  Future<void> _prepareWirelessOverUsb(Device device) async {
    pymd.runner.log.logInfo(
      'Wireless',
      '${device.name} found on USB — pairing wireless services over lockdown',
    );
    await pymd.runner.log.logStep(
      'Pairing wireless services over USB',
      () => pymd.run(lockdownRemotePairArgs(device.udid)),
    );
    await pymd.runner.log.logStep(
      'Enabling Wi-Fi connections',
      () => pymd.run(lockdownWifiArgs(device.udid)),
    );

    await TunnelDaemon(pymd).ensureRunning();
    final tunnel =
        await TunnelDiscovery(
          pymd.runner.log,
          localHttp: pymd.localHttp,
        ).discoverTunnel(
          udid: device.udid,
          timeout: _wirelessTunnelTimeout,
          pollInterval: _pollInterval,
        );
    await diskImage.mountOverRsd(tunnel);
    pymd.runner.log.logDone(
      'Device ready '
      '${pymd.runner.log.dim('— paired over USB, wireless RSD tunnel up')}',
    );
    pymd.runner.log.logInfo(
      'Next',
      pymd.runner.log.dim('unplug USB, then xcross flutter run --wifi'),
    );
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
  void _onPairHostLine(String line) {
    // Protocol lines from the bundled runner (see scripts/pair_host.py).
    if (line.startsWith('XCROSS-PAIR-')) {
      _onPairProtocolLine(line);
      return;
    }
    if (line.contains('Pairing attempt from')) {
      pymd.runner.log.logTrace('[pair-host] $line');
      if (!_warnedPairResumeFailure) {
        _warnedPairResumeFailure = true;
        pymd.runner.log.logWarn(
          'the iPhone tried to resume an old pairing with this host and '
          'failed. On the phone, delete "${RemotePairing(pymd).advertiseName}" '
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
      pymd.runner.log.logStatus(line);
    } else {
      pymd.runner.log.logTrace('[pair-host] $line');
    }
  }

  bool _warnedPairResumeFailure = false;

  /// Render the bundled runner's machine-readable protocol.
  void _onPairProtocolLine(String line) {
    final rest = line.split(' ').skip(1).join(' ');
    switch (line.split(' ').first) {
      case 'XCROSS-PAIR-PIN':
        pymd.runner.log.stopStep();
        pymd.runner.log.logStatus('');
        pymd.runner.log.logStatus(
          '  Enter this code on the iPhone: '
          '${pymd.runner.log.ansi.bold}${pymd.runner.log.ansi.green}$rest${pymd.runner.log.ansi.none}',
        );
        pymd.runner.log.logStatus('');
      case 'XCROSS-PAIR-CONNECTED':
        pymd.runner.log.logStatus(
          '${pymd.runner.log.glyph.info} the iPhone connected — pairing…',
        );
      case 'XCROSS-PAIR-RETRY':
        pymd.runner.log.logTrace(
          '[pair-host] attempt failed, still advertising: $rest',
        );
      case 'XCROSS-PAIR-OK':
        pymd.runner.log.logDone('Paired with $rest');
      case 'XCROSS-PAIR-FAIL':
        pymd.runner.log.logTrace('[pair-host] failed: $rest');
      case 'XCROSS-PAIR-ADVERTISING':
        pymd.runner.log.logTrace('[pair-host] advertising $rest');
      case 'XCROSS-PAIR-WAITING':
        pymd.runner.log.logTrace('[pair-host] waiting ${rest}s');
      case 'XCROSS-PAIR-RECORD':
        pymd.runner.log.logTrace('[pair-host] record: $rest');
      default:
        pymd.runner.log.logTrace('[pair-host] $line');
    }
  }

  /// Wait for tunneld to have any RSD tunnel, while the pairing
  /// advertisement (when running) gives the user the chance to create the
  /// pairing it needs. Null when waiting is pointless or nothing appeared.
  Future<Tunnel?> _awaitWirelessTunnel({Process? pairHost}) async {
    final hasRecord = RemotePairing(pymd).pairingRecordIds().isNotEmpty;
    if (pairHost == null && !hasRecord) return null;

    final step = pymd.runner.log.beginStep('Waiting for a wireless device');
    final diagnostics = WirelessWaitDiagnostics(
      pymd: pymd,
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
        final tunnel = await _pollForTunnel(
          deadline,
          diagnostics,
          stopWhen: () => exited,
        );
        if (tunnel != null) {
          step.done();
          return tunnel;
        }
        final pairHostFailed = exited && exitCode != 0 && !hasRecord;
        if (pairHostFailed) {
          step.fail();
          return null;
        }
      }
      // Phase 2: a pairing record exists (fresh or old) — give tunneld one
      // discovery cycle to find the phone and build the tunnel.
      final deadline = DateTime.now().add(_wirelessTunnelTimeout);
      final tunnel = await _pollForTunnel(deadline, diagnostics);
      if (tunnel != null) {
        step.done();
        return tunnel;
      }
      step.fail();
      return null;
    } on Object {
      step.fail();
      rethrow;
    }
  }

  Future<Tunnel?> _pollForTunnel(
    DateTime deadline,
    WirelessWaitDiagnostics diagnostics, {
    bool Function()? stopWhen,
  }) async {
    while (!(stopWhen?.call() ?? false) && DateTime.now().isBefore(deadline)) {
      final tunnel = await _findExistingTunnel();
      if (tunnel != null) return tunnel;
      await diagnostics.tick();
      await Future<void>.delayed(_pollInterval);
    }
    return null;
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
@internal
final class WirelessWaitDiagnostics {
  WirelessWaitDiagnostics({
    required this.pymd,
    required this.step,
    required this.hasRecord,
  });

  final Pymd pymd;

  static const _browseEvery = Duration(seconds: 20);

  final Step step;
  final bool hasRecord;
  DateTime _nextBrowse = DateTime.now();
  bool? _lastAdvertised;

  Future<void> tick() async {
    if (DateTime.now().isBefore(_nextBrowse)) return;
    _nextBrowse = DateTime.now().add(_browseEvery);
    final advertised = await PymdDevices(pymd).wirelessPairingAdvertised();
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
