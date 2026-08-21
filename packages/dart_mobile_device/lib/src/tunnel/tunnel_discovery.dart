import 'dart:convert';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/constants.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/tunnel.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';

export 'package:dart_mobile_device/src/models/tunnel.dart';

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

    // A hand-rolled loop rather than ProcessRunner.pollUntil: a tunneld that
    // refuses to create the tunnel has to abort the wait immediately, and
    // pollUntil has no way to say "stop, more waiting cannot help".
    final step = Log.beginStep('Waiting for RSD tunnel');
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      Map<String, dynamic>? data;
      try {
        data = await _fetch(TunnelConstants.tunneldUrl);
        lastUnreachable = false;
      } on Object catch (e) {
        Log.logTrace('tunneld list request failed: $e');
      }

      if (data != null) {
        final tunnel = _parseTunnelList(data, udid);
        if (tunnel != null) {
          step.done();
          return tunnel;
        }

        // tunneld is up but has no tunnels yet — ask it to create one.
        if (udid != null && !requestedStart) {
          requestedStart = true;
          Log.logTrace(
            '[pymobiledevice3] no RSD tunnel yet — requesting '
            '/start-tunnel for $udid…',
          );
          final started = await _requestStartTunnel(udid);
          if (started.tunnel case final tunnel?) {
            step.done();
            return tunnel;
          }
          if (started.failure case final failure?) {
            step.fail();
            throw _cannotCreateTunnel(udid, failure);
          }
        } else if (!loggedWaiting) {
          loggedWaiting = true;
          Log.logTrace(
            '[pymobiledevice3] waiting for RSD tunnel'
            '${udid != null ? ' ($udid)' : ''}…',
          );
        }
      }
      await Future<void>.delayed(pollInterval);
    }
    step.fail();

    if (lastUnreachable) {
      throw TunnelError(
        'Cannot reach the tunneld REST API on 127.0.0.1:49151.\n\n'
        'Run:\n\n'
        '    xcross tunnel\n\n'
        'Or start it manually (in another terminal, leave it running):\n\n'
        '    ${Pymd.elevatedCommand('remote tunneld')}',
      );
    }
    final target = udid != null ? 'for device $udid' : 'for any device';
    throw TunnelError(
      'No RSD tunnel $target yet (tunneld returned empty).\n\n'
      'Run:\n\n'
      '    xcross tunnel\n\n'
      'Or in another terminal (iOS 17.4+ / 18 / 26):\n\n'
      '    ${Pymd.elevatedCommand('lockdown start-tunnel')}\n\n'
      'Or mount the Developer Disk Image first:\n\n'
      '    ${Pymd.elevatedCommand('mounter auto-mount')}\n\n'
      'Keep the phone unlocked and trusted. usbipd often fails here — '
      'Apple Mobile Device Service + USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 '
      'is more reliable on WSL.',
    );
  }

  /// Single-shot lookup of a tunnel tunneld already has, without polling or
  /// asking it to create one. Returns null instead of throwing when tunneld is
  /// down or has nothing for [udid].
  static Future<Tunnel?> findExistingTunnel({String? udid}) async {
    try {
      final data = await _fetch(TunnelConstants.tunneldUrl);
      return _parseTunnelList(data, udid);
    } on Object {
      return null;
    }
  }

  /// All active tunnels tunneld currently has, keyed by UDID.
  ///
  /// Empty (never throws) when tunneld is down: callers use this to merge
  /// tunneled devices into discovery, where an unreachable tunneld simply
  /// means "no wireless devices yet".
  static Future<Map<String, Tunnel>> activeTunnels() async {
    final Map<String, dynamic> data;
    try {
      data = await _fetch(TunnelConstants.tunneldUrl);
    } on Object catch (e) {
      Log.logTrace('tunneld list request failed: $e');
      return const {};
    }
    final result = <String, Tunnel>{};
    for (final MapEntry(:key, :value) in data.entries) {
      if (value case [final Map<Object?, Object?> first, ...]) {
        final tunnel = _tunnelFromJson(first);
        if (tunnel != null) result[key] = tunnel;
      }
    }
    return result;
  }

  /// `GET /start-tunnel?udid=` — a `{address,port}` tunnel, or the reason
  /// tunneld refused to create one (typically 404/501).
  ///
  /// Both fields are null when tunneld answered with a body that carries no
  /// usable endpoint: nothing went wrong, so the caller keeps waiting.
  static Future<({Tunnel? tunnel, String? failure})> _requestStartTunnel(
    String udid,
  ) async {
    final uri = Uri.parse(TunnelConstants.tunneldUrl).replace(
      path: '/start-tunnel',
      queryParameters: <String, String>{'udid': udid},
    );
    try {
      final data = await _fetch(uri.toString());
      return (tunnel: _tunnelFromJson(data), failure: null);
    } on Object catch (e) {
      Log.logTrace('tunneld /start-tunnel failed: $e');
      return (tunnel: null, failure: '$e');
    }
  }

  /// tunneld is running but cannot build the tunnel itself: it needs the
  /// Developer Disk Image mounted and a lockdown tunnel, which is what
  /// `xcross tunnel` sets up.
  static TunnelError _cannotCreateTunnel(String udid, String detail) =>
      TunnelCreationError(
        'tunneld could not create an RSD tunnel for $udid.\n\n'
        'Run:\n\n'
        '    xcross tunnel\n\n'
        'Or manually (leave the second one running):\n\n'
        '    ${Pymd.elevatedCommand('mounter auto-mount')}\n'
        '    ${Pymd.elevatedCommand('lockdown start-tunnel')}\n\n'
        'Keep the phone unlocked and trusted.\n\n'
        'tunneld said: $detail',
      );

  static Future<Map<String, dynamic>> _fetch(String url) async {
    final client = LocalHttp.client(
      connectionTimeout: const Duration(seconds: 5),
    );
    // /start-tunnel can block while creating the TUN — allow longer.
    client.idleTimeout = const Duration(seconds: 60);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TunnelError(
          'tunneld returned HTTP ${response.statusCode}: $body',
        );
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw TunnelError('tunneld returned non-object JSON');
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
      // Keep the per-device tunnel list intact. Flattening it here turns each
      // candidate into a map, while the loop below intentionally expects one
      // list per device and therefore silently skips every selected device.
      candidates = <Object?>[root[udid]];
    } else {
      candidates = root.values.toList();
    }

    for (final value in candidates) {
      if (value case [final Map<Object?, Object?> first, ...]) {
        final tunnel = _tunnelFromJson(first);
        if (tunnel != null) return tunnel;
      }
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
    final port = Pymd.asPort(portObj);
    if (addr == null || port == null) return null;
    Log.logTrace('found RSD tunnel: $addr:$port');
    return Tunnel(address: addr, port: port);
  }
}
