import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mobile_device/src/tunnel/port_forwarder.dart';
import 'package:test/test.dart';

import 'test_device_sockets.dart';
import 'test_log_output.dart';

void main() {
  test('forwarder bind failure uses only supplied port', () async {
    final error = StateError('fake bind denied');
    final sockets = TestDeviceSockets(bindFailure: error);
    await expectLater(
      PortForwarder.start(
        sockets: sockets,
        log: testLog(),
        deviceHost: 'not-a-native-host',
        devicePort: 4567,
      ),
      throwsA(same(error)),
    );
    expect(sockets.bindings, [0]);
    expect(sockets.connections, isEmpty);
  });

  test('close releases a device socket arriving after pending dial', () async {
    final ready = Completer<void>();
    final disconnected = Completer<void>();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      addTearDown(socket.destroy);
      socket.listen((_) {}, onDone: disconnected.complete);
    });
    final sockets = TestDeviceSockets(
      destination: (host: server.address.address, port: server.port),
      connectReady: ready.future,
    );
    final forwarder = await PortForwarder.start(
      sockets: sockets,
      log: testLog(),
      deviceHost: '[fe80::5678%en0]',
      devicePort: 4567,
    );
    addTearDown(forwarder.close);
    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      forwarder.localPort,
    );
    addTearDown(client.destroy);
    await sockets.connectionRequested.future.timeout(
      const Duration(seconds: 2),
    );
    await forwarder.close();
    ready.complete();
    await disconnected.future.timeout(const Duration(seconds: 2));
    expect(sockets.bindings, [0]);
    expect(sockets.connections.single.host, 'fe80::5678%en0');
  });

  group('PortForwarder', () {
    late ServerSocket device;

    setUp(() async {
      // Stands in for the VM Service on the phone: echoes, then stays open.
      device = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      device.listen((socket) {
        socket.listen(socket.add, onDone: socket.close);
      });
    });

    // Must stay a closure: a `device.close` tear-off is evaluated at group
    // registration time, before setUp assigns it.
    tearDown(() async {
      await device.close();
    });

    test('carries bytes in both directions', () async {
      final sockets = TestDeviceSockets(
        destination: (host: device.address.address, port: device.port),
      );
      final forwarder = await PortForwarder.start(
        sockets: sockets,
        log: testLog(),
        deviceHost: '[fe80::1234%en0]',
        devicePort: 4567,
      );
      addTearDown(forwarder.close);

      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        forwarder.localPort,
      );
      // Newline-terminated so the reader below sees a complete line without
      // waiting for EOF.
      client.write('getVersion\n');
      await client.flush();

      // Round-trip proves both pipe directions are wired.
      final reply = await utf8.decoder
          .bind(client)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      expect(reply, 'getVersion');
      expect(sockets.bindings, [0]);
      expect(sockets.connections, [
        (host: 'fe80::1234%en0', port: 4567, timeout: null),
      ]);
      await client.close();
    });

    test('publishes a loopback port, never the device address', () async {
      final forwarder = await PortForwarder.start(
        sockets: TestDeviceSockets(),
        log: testLog(),
        deviceHost: device.address.address,
        devicePort: device.port,
      );
      addTearDown(forwarder.close);

      // The whole point: DevTools gets a plain IPv4 loopback URI, because a
      // bracketed IPv6 tunnel literal does not survive browsers, webviews or
      // the editor's URI forwarding.
      expect(forwarder.localPort, isNot(device.port));
      final uri = Uri.parse('ws://127.0.0.1:${forwarder.localPort}/ws');
      expect(uri.host, '127.0.0.1');
      expect(uri.port, forwarder.localPort);
    });

    test('close stops accepting so the process can exit', () async {
      final forwarder = await PortForwarder.start(
        sockets: TestDeviceSockets(),
        log: testLog(),
        deviceHost: device.address.address,
        devicePort: device.port,
      );
      final port = forwarder.localPort;
      await forwarder.close();

      // A still-listening ServerSocket keeps the Dart event loop alive, which
      // would hang `xcross flutter run` after the session ends.
      await expectLater(
        Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test(
      'a refused device connection drops the client, not the listener',
      () async {
        // Simulate the VM Service being gone: point at a closed port.
        final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final deadPort = dead.port;
        await dead.close();

        final forwarder = await PortForwarder.start(
          sockets: TestDeviceSockets(),
          log: testLog(),
          deviceHost: InternetAddress.loopbackIPv4.address,
          devicePort: deadPort,
        );
        addTearDown(forwarder.close);

        final client = await Socket.connect(
          InternetAddress.loopbackIPv4,
          forwarder.localPort,
        );
        // Our side closes the client; the forwarder itself must survive so a
        // later retry (DevTools reconnecting) still works.
        expect(await client.isEmpty, isTrue);
        final second = await Socket.connect(
          InternetAddress.loopbackIPv4,
          forwarder.localPort,
        );
        second.destroy();
      },
    );
  });
}
