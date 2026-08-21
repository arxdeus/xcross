import 'dart:convert';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/device.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:meta/meta.dart';

/// pymobiledevice3-backed device enumeration and app install.
///
/// Same shape as [Pymd]: static-only, builds on [Pymd.run]/[Pymd.resolve]
/// rather than a competing subprocess abstraction. Kept as a separate class
/// (not added to [Pymd] itself) since Dart can't extend an `abstract final`
/// class from another file.
abstract final class PymdDevices {
  /// How long `bonjour mobdev2` is allowed to browse the local network.
  static const _bonjourTimeout = 5;

  /// `pymobiledevice3 usbmux list [--usb|--network]`.
  ///
  /// Unlike `--simple` (bare UDID array), the default output includes device
  /// names and connection type, which is what's needed for [Device].
  ///
  /// Wireless devices do not need usbmuxd at all: when it is unreachable (on
  /// Linux the daemon is socket-activated and only runs while a phone is
  /// plugged in) or simply knows about no network device, fall back to
  /// `pymobiledevice3 bonjour mobdev2`, which finds paired devices over
  /// mDNS. USB-only searches keep the old usbmuxd error, since without the
  /// daemon they truly cannot work.
  static Future<List<Device>> devices({
    DeviceSearchMode mode = DeviceSearchMode.all,
  }) async {
    final args = <String>[
      'usbmux',
      'list',
      if (mode == DeviceSearchMode.usb) '--usb',
      if (mode == DeviceSearchMode.wifi) '--network',
    ];
    final wirelessAllowed = mode != DeviceSearchMode.usb;

    List<Device> viaUsbmux;
    try {
      final result = await Pymd.run(args);
      viaUsbmux = parseDevices(
        result.stdout,
        allowEmptyOutput: wirelessAllowed,
      );
    } on TunnelError {
      if (!wirelessAllowed) rethrow;
      viaUsbmux = const [];
    }
    if (!wirelessAllowed || viaUsbmux.isNotEmpty) return viaUsbmux;

    final viaBonjour = await _bonjourDevices();
    if (viaBonjour.isEmpty) return viaUsbmux;

    final known = viaUsbmux.map((d) => d.udid).toSet();
    return [...viaUsbmux, ...viaBonjour.where((d) => !known.contains(d.udid))];
  }

  /// `pymobiledevice3 bonjour mobdev2` — paired devices advertising
  /// `_apple-mobdev2._tcp` on the local network. Best-effort: a browse that
  /// fails (no mDNS responder, no permission) is treated as "found nothing".
  static Future<List<Device>> _bonjourDevices() async {
    try {
      final result = await Pymd.run([
        'bonjour',
        'mobdev2',
        '--timeout',
        '$_bonjourTimeout',
      ]);
      return parseBonjourDevices(result.stdout);
    } on Object catch (e) {
      Log.logTrace('bonjour mobdev2 browse failed: $e');
      return const [];
    }
  }

  /// Parse the JSON array printed by `pymobiledevice3 bonjour mobdev2`. Each
  /// entry is a lockdown "short info" map plus the discovered `ip`:
  /// ```json
  /// [{"Identifier": "00008030-…", "DeviceName": "iPhone", "ip": "10.0.0.4"}]
  /// ```
  /// Everything found this way is, by definition, a network device.
  @visibleForTesting
  static List<Device> parseBonjourDevices(String output) {
    if (output.trim().isEmpty) return const [];
    final Object? json;
    try {
      json = jsonDecode(output);
    } on FormatException {
      return const [];
    }
    if (json is! List) return const [];
    final devices = <Device>[];
    for (final entry in json) {
      if (entry is! Map) continue;
      final udid =
          (entry['UniqueDeviceID'] ?? entry['Identifier']) as String? ?? '';
      if (udid.isEmpty) continue;
      devices.add(
        Device(
          name: (entry['DeviceName'] as String?) ?? udid,
          udid: udid,
          type: ConnectionType.wifi,
        ),
      );
    }
    return devices;
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
  static List<Device> parseDevices(
    String output, {
    bool allowEmptyOutput = false,
  }) {
    // `usbmux list` exits 0 even when it cannot reach usbmuxd: it logs
    // "Failed to connect to usbmuxd socket" to stderr and prints nothing,
    // so Pymd.run's exit-code check passes and jsonDecode('') would blow up
    // with a bare FormatException stack trace. Turn the empty case into the
    // actionable message instead.
    if (output.trim().isEmpty) {
      if (allowEmptyOutput) return const [];
      throw TunnelError(
        'pymobiledevice3 could not list devices — usbmuxd is not reachable.\n'
        'Start it, then retry:\n'
        '    sudo systemctl start usbmuxd\n'
        'If the phone is attached over usbipd, also check '
        'USBMUXD_SOCKET_ADDRESS.',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(output);
    } on FormatException catch (e) {
      throw TunnelError(
        'pymobiledevice3 usbmux list printed non-JSON output ($e): $output',
      );
    }
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
