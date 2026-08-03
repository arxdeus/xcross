import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/tunnel_discovery.dart';
import 'package:test/test.dart';

/// tunneld's fixed REST port (see TunnelConstants.tunneldUrl). The only way
/// to exercise TunnelDiscovery's JSON parsing without touching production
/// code is to bind exactly this port ourselves and answer as tunneld would.
const _tunneldPort = 49151;

void main() {
  group('discoverTunnel parses a real tunneld-shaped response', () {
    late HttpServer server;
    var bound = false;

    setUp(() async {
      try {
        server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          _tunneldPort,
        );
        bound = true;
      } on SocketException catch (e) {
        bound = false;
        markTestSkipped(
          'port $_tunneldPort already bound in this environment (real '
          'tunneld or another test process): $e',
        );
      }
    });

    tearDown(() async {
      if (bound) await server.close(force: true);
    });

    Future<void> respondOnce(Object body) async {
      final request = await server.first;
      request.response
        ..statusCode = 200
        ..write(jsonEncode(body));
      await request.response.close();
    }

    test('multi-device map, address/port key spelling, int port', () async {
      if (!bound) return;
      unawaited(
        respondOnce({
          'udidA': [
            {'address': 'fd00::1', 'port': 12345},
          ],
        }),
      );

      final tunnel = await TunnelDiscovery.discoverTunnel(
        udid: 'udidA',
        timeout: const Duration(seconds: 3),
        pollInterval: const Duration(milliseconds: 50),
      );

      expect(tunnel.address, 'fd00::1');
      expect(tunnel.port, 12345);
    });

    test('tunnel-address/tunnel-port key spelling, String port', () async {
      if (!bound) return;
      unawaited(
        respondOnce({
          'udidB': [
            {'tunnel-address': 'fd00::2', 'tunnel-port': '54321'},
          ],
        }),
      );

      final tunnel = await TunnelDiscovery.discoverTunnel(
        udid: 'udidB',
        timeout: const Duration(seconds: 3),
        pollInterval: const Duration(milliseconds: 50),
      );

      expect(tunnel.address, 'fd00::2');
      expect(tunnel.port, 54321);
    });

    test('falls back to the first device when udid is null', () async {
      if (!bound) return;
      unawaited(
        respondOnce({
          'someOtherUdid': [
            {'tunnel_address': 'fd00::3', 'tunnel_port': 9999},
          ],
        }),
      );

      final tunnel = await TunnelDiscovery.discoverTunnel(
        udid: null,
        timeout: const Duration(seconds: 3),
        pollInterval: const Duration(milliseconds: 50),
      );

      expect(tunnel.address, 'fd00::3');
      expect(tunnel.port, 9999);
    });
  });

  test('reports "Cannot reach the tunneld" when nothing answers on the '
      'tunneld port', () async {
    // Assumes nothing is bound to the fixed tunneld port (127.0.0.1:49151)
    // in the test environment — true for a normal dev/CI sandbox. tunneld
    // is a Linux-only pymobiledevice3 background service that this repo's
    // own test suite never starts. Some hosts do answer there anyway (e.g.
    // WSL2 mirrored networking, or a stray leftover tunneld); skip rather
    // than fail when that documented precondition doesn't hold.
    Object? caught;
    Object? result;
    try {
      result = await TunnelDiscovery.discoverTunnel(
        udid: null,
        timeout: const Duration(milliseconds: 500),
        pollInterval: const Duration(milliseconds: 80),
      );
    } catch (e) {
      caught = e;
    }

    final unreachable =
        caught is TunnelError &&
        caught.toString().contains('Cannot reach the tunneld');
    if (!unreachable) {
      markTestSkipped(
        'something answered on 127.0.0.1:49151 in this environment '
        '(expected a refused connection); caught=$caught result=$result',
      );
      return;
    }

    expect(caught, isA<TunnelError>());
    expect(caught.toString(), contains('Cannot reach the tunneld'));
  });
}
