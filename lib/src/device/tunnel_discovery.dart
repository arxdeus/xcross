import 'dart:convert';
import 'dart:io';

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/models/device/tunnel.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

export 'package:xcross/src/models/device/tunnel.dart';

/// Stateless REST client for the locally-running tunneld HTTP API. Polls until
/// a tunnel is available; when the list is empty, asks tunneld to create one
/// via `GET /start-tunnel?udid=…`.
abstract final class TunnelDiscovery {
  /// Find the tunnel endpoint for [udid] (or the first tunneled device when
  /// [udid] is null). Retries until [timeout], sleeping [pollInterval] between
  /// attempts. When [udid] is set and the tunnel list is empty, triggers
  /// tunneld's on-demand `/start-tunnel` endpoint (iOS 17.4+ lockdown path).
  static Future<Tunnel> discoverTunnel({
    required String? udid,
    Duration timeout = const Duration(seconds: 60),
    Duration pollInterval = const Duration(milliseconds: 1500),
  }) async {
    var lastUnreachable = true;
    var requestedStart = false;
    var loggedWaiting = false;

    final step = beginStep('Waiting for RSD tunnel');
    final found = await pollUntil<Tunnel>(
      timeout: timeout,
      interval: pollInterval,
      attempt: () async {
        final data = await _fetch(DeviceConstants.tunneldUrl);
        lastUnreachable = false;
        final tunnel = _parseTunnelList(data, udid);
        if (tunnel != null) return tunnel;

        // tunneld is up but has no tunnels yet — ask it to create one.
        if (udid != null && !requestedStart) {
          requestedStart = true;
          logTrace(
            '[pymobiledevice3] no RSD tunnel yet — requesting '
            '/start-tunnel for $udid…',
          );
          return _requestStartTunnel(udid);
        }
        if (!loggedWaiting) {
          loggedWaiting = true;
          logTrace(
            '[pymobiledevice3] waiting for RSD tunnel'
            '${udid != null ? ' ($udid)' : ''}…',
          );
        }
        return null;
      },
    );
    if (found != null) {
      step.done();
      return found;
    }
    step.fail();

    if (lastUnreachable) {
      throw XcrossError(
        'Cannot reach the tunneld REST API on 127.0.0.1:49151.\n\n'
        'Run:\n\n'
        '    xcross prepare\n\n'
        'Or start it manually (in another terminal, leave it running):\n\n'
        '    sudo pymobiledevice3 remote tunneld',
      );
    }
    final target = udid != null ? 'for device $udid' : 'for any device';
    throw XcrossError(
      'No RSD tunnel $target yet (tunneld returned empty).\n\n'
      'Run:\n\n'
      '    xcross prepare\n\n'
      'Or in another terminal (iOS 17.4+ / 18 / 26):\n\n'
      '    sudo pymobiledevice3 lockdown start-tunnel\n\n'
      'Or mount the Developer Disk Image first:\n\n'
      '    sudo pymobiledevice3 mounter auto-mount\n\n'
      'Keep the phone unlocked and trusted. usbipd often fails here — '
      'Apple Mobile Device Service + USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 '
      'is more reliable on WSL.',
    );
  }

  /// `GET /start-tunnel?udid=` — returns a single `{address,port}` tunnel or
  /// null if tunneld could not create one (501/404).
  static Future<Tunnel?> _requestStartTunnel(String udid) async {
    final uri = Uri.parse(DeviceConstants.tunneldUrl).replace(
      path: '/start-tunnel',
      queryParameters: <String, String>{'udid': udid},
    );
    try {
      final data = await _fetch(uri.toString());
      return _tunnelFromJson(data);
    } on Object catch (e) {
      logWarn('tunneld /start-tunnel failed: $e');
    }
    return null;
  }

  static Future<Map<String, dynamic>> _fetch(String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    // /start-tunnel can block while creating the TUN — allow longer.
    client.idleTimeout = const Duration(seconds: 60);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw XcrossError(
          'tunneld returned HTTP ${response.statusCode}: $body',
        );
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw XcrossError('tunneld returned non-object JSON');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  /// Parse the `GET /` multi-device map: `{udid: [{address,port}, …], …}`.
  static Tunnel? _parseTunnelList(Map<String, dynamic> root, String? udid) {
    if (root.isEmpty) return null;

    final List<Object?> candidates;
    if (udid != null && root.containsKey(udid)) {
      final Object? entry = root[udid];
      candidates = entry is List ? List<Object?>.from(entry) : <Object?>[entry];
    } else {
      candidates = root.values.toList();
    }

    for (final value in candidates) {
      if (value is! List) continue;
      if (value.isEmpty) continue;
      final first = value.first;
      if (first is! Map) continue;

      final tunnel = _tunnelFromJson(first);
      if (tunnel != null) return tunnel;
    }
    return null;
  }

  /// Coerce one `{address, port}` object into a [Tunnel], or null if either
  /// field is missing/unparseable.
  ///
  /// Accepts the union of the key spellings seen from `GET /` and
  /// `GET /start-tunnel`; the two endpoints do not agree on them across
  /// pymobiledevice3 versions, and port arrives as int or String.
  static Tunnel? _tunnelFromJson(Map<Object?, Object?> json) {
    final addrObj =
        json['tunnel-address'] ?? json['address'] ?? json['tunnel_address'];
    final portObj = json['tunnel-port'] ?? json['port'] ?? json['tunnel_port'];
    final addr = addrObj is String ? addrObj : null;
    final port = switch (portObj) {
      final int p => p,
      final String p => int.tryParse(p),
      _ => null,
    };
    if (addr == null || port == null) return null;
    logTrace('found RSD tunnel: $addr:$port');
    return Tunnel(address: addr, port: port);
  }
}
