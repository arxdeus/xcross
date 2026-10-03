import 'dart:io';

abstract interface class DeviceSockets {
  Future<Socket> connect(String host, int port, {Duration? timeout});

  Future<ServerSocket> bindLoopback({int port = 0});
}
