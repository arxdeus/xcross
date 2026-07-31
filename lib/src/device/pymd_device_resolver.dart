import 'dart:io';

import 'package:xcross/src/device/pymd_devices.dart';
import 'package:xcross/src/models/device/device.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/xtool/xtool_cli.dart' show DeviceSearchMode;

/// Resolves a target [Device] via pymobiledevice3-backed listing.
///
/// Mirrors `XtoolCli.resolveDevice`'s selector/interactive-picker contract
/// exactly (same matching rules, same TTY-vs-non-TTY behavior), so it is a
/// drop-in replacement once wired into the run pipeline.
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
        throw XcrossError('No connected device matching "$selector".');
      }
      return match.first;
    }
    if (list.isEmpty) {
      throw XcrossError(
        'No devices connected. Connect an iPhone (and tap Trust), then retry.',
      );
    }
    if (list.length == 1) return list.first;
    return _pickDeviceInteractively(list);
  }

  /// Prompt the user to pick a device from [list].
  ///
  /// Falls back to an [XcrossError] when stdin is not a TTY (e.g. CI, piped
  /// input) so scripts fail fast instead of hanging on a prompt.
  Device _pickDeviceInteractively(List<Device> list) {
    if (!stdin.hasTerminal) {
      final names = list.map((d) => '  $d').join('\n');
      throw XcrossError(
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
          throw XcrossError('No selection made (stdin closed).');
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
