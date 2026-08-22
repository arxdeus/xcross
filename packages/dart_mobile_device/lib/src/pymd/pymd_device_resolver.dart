import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/device.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:dart_mobile_device/src/pymd/pymd_devices.dart';
import 'package:dart_mobile_device/src/pymd/remote_pairing.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_daemon.dart';

/// Resolves a target [Device] via pymobiledevice3-backed listing.
class PymdDeviceResolver {
  /// How long the wireless bring-up waits for tunneld to find the device and
  /// build its RSD tunnel. tunneld's Wi-Fi monitor rescans every 5 s and the
  /// RemotePairing handshake takes a few more, so this needs to be generous.
  static const Duration wirelessDiscoveryTimeout = Duration(seconds: 45);

  static const Duration _pollInterval = Duration(seconds: 2);

  /// Resolve a single target device.
  ///
  /// If [selector] is given it must match a connected device by UDID or name
  /// (flutter's `-d/--device-id` accepts either). Otherwise, if exactly one
  /// device is connected it is used; if several are connected and stdin is a
  /// TTY, an interactive numbered picker is shown; on non-TTY (CI, piped)
  /// stdin, an error listing the candidates is thrown so the caller can pass
  /// `--udid`/`-d` to disambiguate.
  ///
  /// When the search allows wireless devices and nothing (matching) is found,
  /// the resolver actively brings wireless discovery up: it starts tunneld
  /// (the component that finds `_remotepairing._tcp` devices over mDNS and
  /// builds their RSD tunnels — the only Wi-Fi path on Linux/Windows) and
  /// polls until the device appears or [wirelessDiscoveryTimeout] passes.
  ///
  /// Before that search, `--wifi` bootstraps what it can:
  ///
  /// * Phone on USB right now → the cable does the setup: Wi-Fi connections
  ///   are switched on over usbmux, and tunneld (started next) pairs and
  ///   builds the first tunnel through the cable's NCM interface. This run
  ///   connects immediately, and later runs work with no cable at all.
  /// * No USB and no pairing record → wireless cannot possibly succeed, so
  ///   the host advertises for device-initiated pairing (iOS 27+) and walks
  ///   the user through accepting it on the phone.
  Future<Device> resolveDevice({
    String? selector,
    DeviceSearchMode mode = DeviceSearchMode.all,
  }) async {
    var list = await PymdDevices.devices(mode: mode);
    // Active bring-up only when the user explicitly asked for Wi-Fi: in
    // `all` mode an empty list usually means "forgot to plug the phone in",
    // and starting a root daemon plus a 45 s scan there would be hostile.
    if (mode == DeviceSearchMode.wifi && _matches(list, selector).isEmpty) {
      await _prepareWireless(selector);
      list = await _bringUpWireless(mode: mode, selector: selector);
    }

    if (selector != null) {
      final match = _matches(list, selector);
      if (match.isEmpty) {
        if (list.isEmpty && mode == DeviceSearchMode.wifi) {
          throw TunnelError(await _noWirelessDeviceMessage(_daemonFailure));
        }
        throw TunnelError('No connected device matching "$selector".');
      }
      return match.first;
    }
    if (list.isEmpty) {
      throw TunnelError(switch (mode) {
        DeviceSearchMode.wifi => await _noWirelessDeviceMessage(_daemonFailure),
        DeviceSearchMode.usb =>
          'No devices connected. Connect an iPhone (and tap Trust), '
              'then retry.',
        DeviceSearchMode.all =>
          'No devices connected. Connect an iPhone over USB (and tap '
              'Trust), or use --wifi for a wireless device, then retry.',
      });
    }
    if (list.length == 1) return list.first;
    return _pickDeviceInteractively(list);
  }

  /// Why tunneld could not be started this session, when it could not be.
  /// Wireless discovery is impossible without it, so the final "no device"
  /// message must lead with this instead of guessing at pairing problems.
  TunnelError? _daemonFailure;

  /// Devices matching [selector] (UDID with or without dashes, or name).
  /// With a null selector: the whole list.
  List<Device> _matches(List<Device> list, String? selector) {
    if (selector == null) return list;
    final normalized = PymdDevices.normalizeUdid(selector);
    return [
      for (final device in list)
        if (PymdDevices.normalizeUdid(device.udid) == normalized ||
            device.name == selector)
          device,
    ];
  }

  /// Bootstrap wireless connectivity before the tunneld search, using
  /// whatever is available: the USB cable when the phone is plugged in,
  /// device-initiated pairing when it is not. Best-effort — the search runs
  /// either way, and its error message covers the manual routes.
  Future<void> _prepareWireless(String? selector) async {
    final overUsb = _matches(await _usbDevices(), selector);
    if (overUsb.isNotEmpty) {
      await _enableWifiConnectionsOverUsb(overUsb.first);
      return;
    }
    if (!RemotePairing.shouldOfferPairing(selector)) return;
    if (!stdout.hasTerminal) {
      Log.logTrace(
        'wireless bring-up: no pairing record and no terminal to run '
        'device-initiated pairing on — skipping pair-host',
      );
      return;
    }
    Log.logInfo(
      'Wireless',
      'no pairing with this host yet — starting device-initiated pairing',
    );
    _offeredPairHost = true;
    await RemotePairing.advertisePairHost();
  }

  /// Whether this resolution already ran a pair-host advertisement, so the
  /// post-search rescue does not immediately ask the user to pair twice.
  bool _offeredPairHost = false;

  /// Last resort after a fruitless search: the phone is not connecting to
  /// tunneld, which (network aside) means the pairing is gone on the phone's
  /// side — deleting the host entry there leaves our record behind, and the
  /// pre-flight "record exists, all good" check cannot see that. Advertise
  /// for a fresh device-initiated pairing and keep polling discovery while
  /// the user pairs; a phone that silently reconnects on the old record wins
  /// the race and the advertisement is killed.
  Future<List<Device>> _rescueWithPairHost({
    required DeviceSearchMode mode,
    required String? selector,
    required List<Device> last,
  }) async {
    if (_offeredPairHost || !stdout.hasTerminal) return last;
    _offeredPairHost = true;

    Log.logInfo(
      'Wireless',
      'no device connected — its pairing with this host may have been '
          'removed on the phone. Starting device-initiated pairing.',
    );
    final process = await RemotePairing.startPairHost();
    if (process == null) return last;

    var exited = false;
    final exitFuture = process.exitCode.then((code) {
      exited = true;
      return code;
    });
    var list = last;
    final deadline = DateTime.now().add(RemotePairing.pairHostTimeout);
    while (DateTime.now().isBefore(deadline)) {
      list = await PymdDevices.devices(mode: mode);
      if (_matches(list, selector).isNotEmpty) {
        process.kill();
        return list;
      }
      if (exited) break;
      await Future<void>.delayed(_pollInterval);
    }
    if (!exited) {
      process.kill();
      return list;
    }
    if (await exitFuture != 0) return list;

    // Paired: the record is fresh, so give tunneld one more full search to
    // notice the phone and build its tunnel.
    final step = Log.beginStep('Searching for wireless devices');
    final searchDeadline = DateTime.now().add(wirelessDiscoveryTimeout);
    while (DateTime.now().isBefore(searchDeadline)) {
      list = await PymdDevices.devices(mode: mode);
      if (_matches(list, selector).isNotEmpty) {
        step.done();
        return list;
      }
      await Future<void>.delayed(_pollInterval);
    }
    step.fail();
    return list;
  }

  /// USB-attached devices, or an empty list when usbmuxd is unreachable
  /// (routine on Linux with no cable plugged in).
  Future<List<Device>> _usbDevices() async {
    try {
      return await PymdDevices.devices(mode: DeviceSearchMode.usb);
    } on TunnelError {
      return const [];
    }
  }

  /// Switch `EnableWifiConnections` on through the cable — the lockdown
  /// setting Finder calls "Show this iPhone when on Wi-Fi", without which
  /// the phone stops advertising itself once the cable is out. Idempotent.
  ///
  /// tunneld (started right after) does the rest over the same cable: its
  /// USB monitor pairs RemotePairing and builds this session's tunnel, and
  /// the saved records let both wireless monitors reconnect cable-free.
  Future<void> _enableWifiConnectionsOverUsb(Device device) async {
    Log.logInfo(
      'Wireless',
      'phone found on USB — setting Wi-Fi connections up over the cable',
    );
    try {
      await Pymd.run([
        'lockdown',
        'wifi-connections',
        '--state',
        'on',
        '--udid',
        device.udid,
      ]);
    } on TunnelError catch (e) {
      // A trust prompt the user dismissed, a locked phone, a password-set
      // requirement: all leave wireless possibly working anyway (tunneld
      // pairs on its own), so warn and continue rather than abort.
      Log.logWarn(
        'could not enable Wi-Fi connections over USB — unlock the phone '
        'and tap Trust, then re-run if wireless discovery fails.',
      );
      Log.logTrace(e.message);
    }
  }

  /// Start tunneld and poll discovery until a (matching) wireless device
  /// appears or the timeout passes. Returns the last device list either way.
  ///
  /// tunneld needs root for its TUN interface; without it this quietly
  /// returns, and the final error message explains the manual route.
  ///
  /// tunneld's own output goes to a log file, not this terminal, so the poll
  /// tails that file into the step (and into `--verbose` trace): a tunnel
  /// failing per-attempt — stale pairing record, wrong protocol, throttling —
  /// is otherwise indistinguishable from a phone that simply is not there.
  /// The one failure with a *known* automatic fix gets fixed on the spot: a
  /// pre-existing xcross tunneld still speaking QUIC to an iOS that removed
  /// it (18.2+) is restarted with `--protocol tcp`.
  Future<List<Device>> _bringUpWireless({
    required DeviceSearchMode mode,
    required String? selector,
  }) async {
    final daemon = TunnelDaemon();
    try {
      await daemon.ensureRunning();
    } on TunnelError catch (e) {
      _daemonFailure = e;
      Log.logTrace('wireless bring-up: tunneld unavailable: $e');
      return PymdDevices.devices(mode: mode);
    }

    final tail = TunneldLogTail.start();
    var step = Log.beginStep('Searching for wireless devices');
    var list = <Device>[];
    var restartedForQuic = false;
    try {
      var deadline = DateTime.now().add(wirelessDiscoveryTimeout);
      while (DateTime.now().isBefore(deadline)) {
        list = await PymdDevices.devices(mode: mode);
        if (_matches(list, selector).isNotEmpty) {
          step.done();
          return list;
        }
        final chunk = tail.readNew();
        if (chunk.isNotEmpty) step.log(chunk);
        if (!restartedForQuic && tail.sawQuicUnsupported) {
          restartedForQuic = true;
          // restartStale opens its own steps, so close this one first and
          // reopen (with a fresh discovery budget) after.
          step.fail();
          Log.logWarn(
            'tunneld is speaking QUIC to an iOS that removed it — '
            'restarting it with --protocol tcp',
          );
          if (!await daemon.restartStale()) {
            throw TunnelError(
              'tunneld is running with the QUIC protocol, which iOS 18.2+ '
              'removed, so its wireless tunnels always fail. Restart it '
              'with TCP:\n'
              '    ${Pymd.elevatedCommand('remote tunneld -p tcp')}',
            );
          }
          step = Log.beginStep('Searching for wireless devices');
          deadline = DateTime.now().add(wirelessDiscoveryTimeout);
        }
        await Future<void>.delayed(_pollInterval);
      }
      step.fail();
      final log = tail.seen.trim();
      if (log.isNotEmpty) {
        Log.logTrace('tunneld output during the search:\n$log');
      }
      return await _rescueWithPairHost(
        mode: mode,
        selector: selector,
        last: list,
      );
    } on Object {
      step.fail();
      rethrow;
    }
  }

  /// Explain an empty wireless search, assuming no Xcode or Finder: every
  /// step here works on a bare Linux/Windows host with pymobiledevice3.
  ///
  /// When the phone is visibly advertising `_remotepairing._tcp` the problem
  /// is pairing, not the network, so say exactly that.
  ///
  /// When tunneld itself never started ([daemonFailure]), pairing hints are
  /// noise: nothing was going to be discovered no matter what, so lead with
  /// the daemon's own error instead.
  static Future<String> _noWirelessDeviceMessage([
    TunnelError? daemonFailure,
  ]) async {
    if (daemonFailure != null) {
      return 'No wireless device found — the RSD tunnel daemon (tunneld) '
          'could not be started, and wireless discovery is impossible '
          'without it:\n${daemonFailure.message}';
    }
    final advertised = await PymdDevices.wirelessPairingAdvertised();
    final buffer = StringBuffer('No wireless device found.\n');
    if (advertised) {
      buffer.writeln(
        'An iPhone on this network is advertising wireless debugging, but '
        'this host is not paired with it.',
      );
    }
    buffer
      ..writeln('Wireless debugging needs a one-time pairing:')
      ..writeln()
      ..writeln('  1. On the iPhone, enable Developer Mode')
      ..writeln('     (Settings > Privacy & Security > Developer Mode).')
      ..writeln(
        '  2. Pair this host over Wi-Fi (a Trust dialog appears on '
        'the phone):',
      )
      ..writeln()
      ..writeln('         pymobiledevice3 remote pair')
      ..writeln()
      ..writeln('     Or plug the phone in over USB once and run:')
      ..writeln()
      ..writeln('         pymobiledevice3 lockdown pair')
      ..writeln()
      ..writeln('  3. Retry with the phone unlocked, on the same network.')
      ..writeln()
      ..writeln(
        'Plugging the phone in over USB and re-running with --wifi also '
        'works: xcross then sets up everything over the cable automatically.',
      );
    if (!advertised) {
      buffer
        ..writeln()
        ..write(
          'No device is advertising wireless debugging right now: also check '
          'that the phone is unlocked, on the same subnet, and that mDNS '
          '(UDP 5353) is not blocked — it does not cross NAT, so bridged '
          'networking is required in a VM or WSL.',
        );
    }
    return buffer.toString().trimRight();
  }

  /// Prompt the user to pick a device from [list].
  ///
  /// Falls back to an [TunnelError] when stdin is not a TTY (e.g. CI, piped
  /// input) so scripts fail fast instead of hanging on a prompt.
  Device _pickDeviceInteractively(List<Device> list) {
    if (!stdin.hasTerminal) {
      final names = list.map((d) => '  $d').join('\n');
      throw TunnelError(
        'Multiple devices connected; pass --udid to choose one:\n$names',
      );
    }

    stdout.writeln('Multiple devices connected. Choose one:');
    for (var i = 0; i < list.length; i++) {
      stdout.writeln('  [${i + 1}] ${list[i]}');
    }

    // Save stdin terminal modes before touching them. On some platforms
    // (Linux /dev/null, Windows without a conhost) reading echoMode / lineMode
    // throws; _tryGet swallows that and returns null so the finally block
    // skips the restore rather than throwing a second error.
    final priorEcho = _tryGet(() => stdin.echoMode);
    final priorLine = _tryGet(() => stdin.lineMode);
    try {
      _trySet(() => stdin.echoMode = true);
      _trySet(() => stdin.lineMode = true);

      while (true) {
        stdout.write('Choice (1-${list.length}): ');
        final raw = stdin.readLineSync()?.trim();
        if (raw == null) {
          throw TunnelError('No selection made (stdin closed).');
        }
        final n = int.tryParse(raw);
        if (n != null && n >= 1 && n <= list.length) {
          return list[n - 1];
        }
        stdout.writeln(
          'Invalid choice "$raw". Enter a number 1-${list.length}.',
        );
      }
    } finally {
      if (priorEcho != null) _trySet(() => stdin.echoMode = priorEcho);
      if (priorLine != null) _trySet(() => stdin.lineMode = priorLine);
    }
  }

  static T? _tryGet<T>(T Function() f) {
    try {
      return f();
    } catch (_) {
      return null;
    }
  }

  static void _trySet(void Function() f) {
    try {
      f();
    } catch (_) {}
  }
}
