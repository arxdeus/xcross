import 'dart:io';

import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/device.dart';
import 'package:dart_mobile_device/src/pymd/pymd_devices.dart';

/// Resolves a target [Device] via pymobiledevice3-backed listing.
class PymdDeviceResolver {
  /// Resolve a single target device.
  ///
  /// If [selector] is given it must match a connected device by UDID or name
  /// (flutter's `-d/--device-id` accepts either). Otherwise, if exactly one
  /// device is connected it is used; if several are connected and stdin is a
  /// TTY, an interactive numbered picker is shown; on non-TTY (CI, piped)
  /// stdin, an error listing the candidates is thrown so the caller can pass
  /// `--udid`/`-d` to disambiguate.
  Future<Device> resolveDevice({
    String? selector,
    DeviceSearchMode mode = DeviceSearchMode.all,
  }) async {
    final list = await PymdDevices.devices(mode: mode);
    if (selector != null) {
      final match = list.where((d) => d.udid == selector || d.name == selector);
      if (match.isEmpty) {
        throw TunnelError('No connected device matching "$selector".');
      }
      return match.first;
    }
    if (list.isEmpty) {
      if (mode == DeviceSearchMode.usb) {
        throw TunnelError(
          'No devices connected. Connect an iPhone (and tap Trust), '
          'then retry.',
        );
      }
      throw TunnelError(await _noWirelessDeviceMessage());
    }
    if (list.length == 1) return list.first;
    return _pickDeviceInteractively(list);
  }

  /// Explain an empty wireless search.
  ///
  /// No Xcode or Finder is assumed: everything here is doable from a Linux
  /// host with pymobiledevice3 alone. When the phone is visibly advertising
  /// `_remotepairing._tcp` the problem is a missing pair record, not the
  /// network, so say exactly that instead of a generic checklist.
  static Future<String> _noWirelessDeviceMessage() async {
    final advertised = await PymdDevices.wirelessPairingAdvertised();
    final buffer = StringBuffer(
      'No devices connected over USB or found over Wi-Fi.\n',
    );
    if (advertised) {
      buffer
        ..writeln(
          'An iPhone is advertising itself on this network, but this host '
          'has no pair record for it.',
        )
        ..writeln('Plug it in once over USB and pair:')
        ..writeln()
        ..writeln('    pymobiledevice3 lockdown pair')
        ..writeln('    pymobiledevice3 lockdown wifi-connections on')
        ..writeln()
        ..write(
          'Then unplug and retry — the pair record under '
          '~/.pymobiledevice3 is what makes wireless discovery work.',
        );
      return buffer.toString();
    }
    buffer
      ..writeln('For a wireless device, check that:')
      ..writeln(
        '  - the iPhone was paired with this host over USB at least once '
        '(pymobiledevice3 lockdown pair) and wireless connections are on '
        '(pymobiledevice3 lockdown wifi-connections on);',
      )
      ..writeln('  - the phone is unlocked and on the same subnet;')
      ..writeln(
        '  - mDNS (UDP 5353) is allowed and reaches the phone — on a '
        'bridged VM or WSL, use a bridged/host network, since mDNS does '
        'not cross NAT;',
      )
      ..write(
        '  - `pymobiledevice3 bonjour mobdev2` finds it; if that is empty '
        'too, the host cannot see the device at all.',
      );
    return buffer.toString();
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
