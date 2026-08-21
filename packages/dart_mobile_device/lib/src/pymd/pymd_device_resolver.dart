import 'dart:io';

import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/device.dart';
import 'package:dart_mobile_device/src/pymd/pymd_devices.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_daemon.dart';

import 'package:cli_kit/cli_kit.dart';

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
  Future<Device> resolveDevice({
    String? selector,
    DeviceSearchMode mode = DeviceSearchMode.all,
  }) async {
    var list = await PymdDevices.devices(mode: mode);
    // Active bring-up only when the user explicitly asked for Wi-Fi: in
    // `all` mode an empty list usually means "forgot to plug the phone in",
    // and starting a root daemon plus a 45 s scan there would be hostile.
    if (mode == DeviceSearchMode.wifi && _matches(list, selector).isEmpty) {
      list = await _bringUpWireless(mode: mode, selector: selector);
    }

    if (selector != null) {
      final match = _matches(list, selector);
      if (match.isEmpty) {
        if (list.isEmpty && mode == DeviceSearchMode.wifi) {
          throw TunnelError(await _noWirelessDeviceMessage());
        }
        throw TunnelError('No connected device matching "$selector".');
      }
      return match.first;
    }
    if (list.isEmpty) {
      throw TunnelError(switch (mode) {
        DeviceSearchMode.wifi => await _noWirelessDeviceMessage(),
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

  /// Start tunneld and poll discovery until a (matching) wireless device
  /// appears or the timeout passes. Returns the last device list either way.
  ///
  /// tunneld needs root for its TUN interface; without it this quietly
  /// returns, and the final error message explains the manual route.
  Future<List<Device>> _bringUpWireless({
    required DeviceSearchMode mode,
    required String? selector,
  }) async {
    try {
      await TunnelDaemon().ensureRunning();
    } on TunnelError catch (e) {
      Log.logTrace('wireless bring-up: tunneld unavailable: $e');
      return PymdDevices.devices(mode: mode);
    }

    final step = Log.beginStep('Searching for wireless devices');
    var list = <Device>[];
    try {
      final deadline = DateTime.now().add(wirelessDiscoveryTimeout);
      while (DateTime.now().isBefore(deadline)) {
        list = await PymdDevices.devices(mode: mode);
        if (_matches(list, selector).isNotEmpty) {
          step.done();
          return list;
        }
        await Future<void>.delayed(_pollInterval);
      }
      step.fail();
      return list;
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
  static Future<String> _noWirelessDeviceMessage() async {
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
      ..writeln('  3. Retry with the phone unlocked, on the same network.');
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
