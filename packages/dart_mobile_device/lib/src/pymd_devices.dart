import 'dart:convert';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/device.dart';
import 'package:dart_mobile_device/src/pymd.dart';

/// pymobiledevice3-backed device enumeration and app install.
///
/// Same shape as [Pymd]: static-only, builds on [Pymd.run]/[Pymd.resolve]
/// rather than a competing subprocess abstraction. Kept as a separate class
/// (not added to [Pymd] itself) since Dart can't extend an `abstract final`
/// class from another file.
abstract final class PymdDevices {
  /// `pymobiledevice3 usbmux list [--usb|--network]`.
  ///
  /// Unlike `--simple` (bare UDID array), the default output includes device
  /// names and connection type, which is what's needed for [Device].
  static Future<List<Device>> devices({
    DeviceSearchMode mode = DeviceSearchMode.all,
  }) async {
    final args = <String>[
      'usbmux',
      'list',
      if (mode == DeviceSearchMode.usb) '--usb',
      if (mode == DeviceSearchMode.wifi) '--network',
    ];
    final result = await Pymd.run(args);
    return parseDevices(result.stdout);
  }

  /// Parse the JSON array printed by `pymobiledevice3 usbmux list` (without
  /// `--simple`). Each entry looks like:
  /// ```json
  /// {
  ///   "ConnectionType": "USB",
  ///   "DeviceName": "iPhone Mind",
  ///   "UniqueDeviceID": "00008030-000664292232802E",
  ///   ...
  /// }
  /// ```
  static List<Device> parseDevices(String output) {
    final dynamic json = jsonDecode(output);
    if (json is! List) {
      throw TunnelError(
        'pymobiledevice3 usbmux list: expected a JSON array, got: $output',
      );
    }
    return json.map((dynamic entry) {
      final map = entry as Map<String, dynamic>;
      final udid = (map['UniqueDeviceID'] ?? map['Identifier']) as String;
      return Device(
        name: (map['DeviceName'] as String?) ?? udid,
        udid: udid,
        type: ConnectionType.parse((map['ConnectionType'] as String?) ?? 'USB'),
      );
    }).toList();
  }

  /// `pymobiledevice3 apps install <path> [--udid <udid>]`.
  ///
  /// Shows a spinner whose grey tail streams pymobiledevice3's own progress
  /// and surfaces failures as [TunnelError]. Does not forward stdin — install
  /// is non-interactive, and a cooked-mode sharedStdin listen here leaves the
  /// later hot-reload `r`/`R`/`q` loop deaf on Windows.
  static Future<void> install(String appOrIpaPath, {String? udid}) async {
    final inv = await Pymd.resolve();
    final args = <String>['apps', 'install', appOrIpaPath];
    if (udid != null) args.addAll(['--udid', udid]);

    final step = Log.beginStep('Installing to device');
    try {
      await ProcessRunner.runChecked(
        inv.executable,
        [...inv.prefixArgs, ...args],
        label: 'pymobiledevice3',
        tail: step,
        forwardStdin: false,
        environment: Pymd.usbmuxEnvironment(),
      );
      step.done();
    } on Object {
      step.fail();
      rethrow;
    }
  }
}
