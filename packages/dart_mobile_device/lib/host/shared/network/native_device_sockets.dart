import 'dart:io';

import 'package:dart_mobile_device/shared/network/device_sockets.dart';

final class NativeDeviceSockets implements DeviceSockets {
  const NativeDeviceSockets();

  @override
  Future<Socket> connect(String host, int port, {Duration? timeout}) =>
      Socket.connect(host, port, timeout: timeout);

  @override
  Future<ServerSocket> bindLoopback({int port = 0}) =>
      ServerSocket.bind(InternetAddress.loopbackIPv4, port);
}
