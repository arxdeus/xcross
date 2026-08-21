import 'dart:convert';
import 'dart:io';

import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';

/// Integration of the tunneld-backed wireless discovery path against a live
/// HTTP server speaking tunneld's `GET /` shape on the real port.
void main() {
  HttpServer? server;

  Future<bool> startFakeTunneld(Map<String, Object?> payload) async {
    try {
      server = await HttpServer.bind('127.0.0.1', 49151);
    } on SocketException {
      // A real tunneld (or another test) owns the port; skip rather than
      // fight over it.
      return false;
    }
    server!.listen((req) {
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(payload))
        ..close();
    });
    return true;
  }

  tearDown(() async {
    await server?.close(force: true);
    server = null;
  });

  test('activeTunnels parses tunneld GET / entries', () async {
    if (!await startFakeTunneld({
      '00008030-000664292232802E': [
        {
          'tunnel-address': 'fd7b:e5b:6f53::1',
          'tunnel-port': 55555,
          'interface': 'utun9',
        },
      ],
      'broken-entry': <Object?>[],
    })) {
      markTestSkipped('port 49151 busy (real tunneld running)');
      return;
    }

    final tunnels = await TunnelDiscovery.activeTunnels();
    expect(tunnels, hasLength(1));
    expect(tunnels['00008030-000664292232802E']!.address, 'fd7b:e5b:6f53::1');
    expect(tunnels['00008030-000664292232802E']!.port, 55555);
  });

  test('activeTunnels is empty when tunneld is down', () async {
    expect(await TunnelDiscovery.activeTunnels(), isEmpty);
  });
}
