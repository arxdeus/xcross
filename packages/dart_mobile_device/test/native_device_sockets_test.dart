import 'dart:io';

import 'package:dart_mobile_device/host/shared/network/native_device_sockets.dart';
import 'package:test/test.dart';

void main() {
  const sockets = NativeDeviceSockets();

  test('native bind and timed connect stay on owned IPv4 loopback', () async {
    final server = await sockets.bindLoopback();
    addTearDown(server.close);
    final accepted = server.first;
    final client = await sockets.connect(
      server.address.address,
      server.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(client.destroy);
    final peer = await accepted;
    addTearDown(peer.destroy);
    expect(server.address, InternetAddress.loopbackIPv4);
    expect(client.remotePort, server.port);
    client.add([1, 2, 3]);
    expect(await peer.first, [1, 2, 3]);
  });

  test('native bind accepts an explicit owned loopback port', () async {
    final reservation = await sockets.bindLoopback();
    final port = reservation.port;
    await reservation.close();
    final server = await sockets.bindLoopback(port: port);
    addTearDown(server.close);
    expect(server.port, port);
    expect(server.address, InternetAddress.loopbackIPv4);
  });
}
