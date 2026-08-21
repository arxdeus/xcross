import 'dart:convert';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/device.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_discovery.dart';
import 'package:meta/meta.dart';

/// pymobiledevice3-backed device enumeration and app install.
///
/// Same shape as [Pymd]: static-only, builds on [Pymd.run]/[Pymd.resolve]
/// rather than a competing subprocess abstraction. Kept as a separate class
/// (not added to [Pymd] itself) since Dart can't extend an `abstract final`
/// class from another file.
abstract final class PymdDevices {
  /// How long a bonjour browse is allowed to look around the local network.
  static const _bonjourTimeout = 5;

  /// Cached `DeviceName` per tunneled UDID, so discovery polling does not
  /// spawn a `lockdown info` subprocess on every tick.
  static final Map<String, String?> _tunnelNameCache = {};

  /// Enumerate reachable devices.
  ///
  /// Two sources are merged:
  ///
  /// * `pymobiledevice3 usbmux list [--usb|--network]` — devices known to
  ///   usbmuxd. On Linux the open-source usbmuxd only ever knows USB devices
  ///   (and is often not even running without one plugged in), so for
  ///   searches that allow wireless devices an unreachable usbmuxd is not an
  ///   error.
  /// * the tunneld REST API — devices with an active RSD tunnel. This is how
  ///   wireless devices appear on Linux/Windows: tunneld's RemotePairing
  ///   monitor finds them over mDNS and builds the tunnel, no usbmuxd
  ///   involved.
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
    if (!wirelessAllowed) return viaUsbmux;

    final viaTunneld = await _tunneldDevices(known: viaUsbmux);
    return [...viaUsbmux, ...viaTunneld];
  }

  /// Devices with an active RSD tunnel in tunneld, excluding [known] ones.
  ///
  /// Best-effort: when tunneld is not running this is simply an empty list.
  static Future<List<Device>> _tunneldDevices({
    required List<Device> known,
  }) async {
    final tunnels = await TunnelDiscovery.activeTunnels();
    if (tunnels.isEmpty) return const [];
    final knownUdids = known.map((d) => normalizeUdid(d.udid)).toSet();
    final result = <Device>[];
    for (final udid in tunnels.keys) {
      if (knownUdids.contains(normalizeUdid(udid))) continue;
      result.add(
        Device(
          name: await _tunneledDeviceName(udid) ?? udid,
          udid: udid,
          type: ConnectionType.wifi,
          source: DeviceSource.tunneld,
        ),
      );
    }
    return result;
  }

  /// `DeviceName` of a tunneled device via `lockdown info --tunnel`.
  static Future<String?> _tunneledDeviceName(String udid) async {
    if (_tunnelNameCache.containsKey(udid)) return _tunnelNameCache[udid];
    String? name;
    try {
      final result = await Pymd.run(['lockdown', 'info', '--tunnel', udid]);
      if (jsonDecode(result.stdout) case {'DeviceName': final String n}) {
        name = n;
      }
    } on Object catch (e) {
      Log.logTrace('lockdown info --tunnel $udid failed: $e');
    }
    return _tunnelNameCache[udid] = name;
  }

  /// Linux usbmuxd sometimes reports UDIDs without the `-` separator, while
  /// tunneld and lockdown keep it. Compare without it.
  @visibleForTesting
  static String normalizeUdid(String udid) => udid.replaceAll('-', '');

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

  /// True when some iOS device advertises `_remotepairing._tcp` on this
  /// network: it is reachable and wireless-debugging capable, whether or not
  /// this host is paired with it. Diagnostics only; never throws.
  static Future<bool> wirelessPairingAdvertised() async {
    try {
      final result = await Pymd.run([
        'bonjour',
        'remotepairing',
        '--timeout',
        '$_bonjourTimeout',
      ]);
      final json = jsonDecode(
        result.stdout.trim().isEmpty ? '[]' : result.stdout,
      );
      return json is List && json.isNotEmpty;
    } on Object catch (e) {
      Log.logTrace('bonjour remotepairing browse failed: $e');
      return false;
    }
  }

  /// `pymobiledevice3 apps install <path> [--udid <udid>|--tunnel <udid>]`.
  ///
  /// [overTunnel] routes the install through tunneld's RSD tunnel instead of
  /// usbmuxd — the only path that works for a wireless device on
  /// Linux/Windows.
  ///
  /// Shows a spinner whose grey tail streams pymobiledevice3's own progress
  /// and surfaces failures as [TunnelError]. Does not forward stdin — install
  /// is non-interactive, and a cooked-mode sharedStdin listen here leaves the
  /// later hot-reload `r`/`R`/`q` loop deaf on Windows.
  static Future<void> install(
    String appOrIpaPath, {
    String? udid,
    bool overTunnel = false,
  }) async {
    final inv = await Pymd.resolve();
    final args = <String>['apps', 'install', appOrIpaPath];
    if (udid != null) {
      args.addAll(overTunnel ? ['--tunnel', udid] : ['--udid', udid]);
    }

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
