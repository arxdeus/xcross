import 'dart:async';
import 'dart:io';

import 'package:dart_mobile_device/src/shared/network/device_sockets.dart';

final class TestDeviceSockets implements DeviceSockets {
  TestDeviceSockets({
    this.destination,
    this.connectFailure,
    this.bindFailure,
    this.connectReady,
  });

  final ({String host, int port})? destination;
  final Object? connectFailure;
  final Object? bindFailure;
  final Future<void>? connectReady;
  final connectionRequested = Completer<void>();
  final connections = <({String host, int port, Duration? timeout})>[];
  final bindings = <int>[];

  @override
  Future<Socket> connect(String host, int port, {Duration? timeout}) async {
    connections.add((host: host, port: port, timeout: timeout));
    if (!connectionRequested.isCompleted) connectionRequested.complete();
    if (connectFailure case final Object failure) {
      return Future.error(failure);
    }
    await connectReady;
    final endpoint = destination ?? (host: host, port: port);
    return Socket.connect(endpoint.host, endpoint.port, timeout: timeout);
  }

  @override
  Future<ServerSocket> bindLoopback({int port = 0}) {
    bindings.add(port);
    if (bindFailure case final Object failure) return Future.error(failure);
    return ServerSocket.bind(InternetAddress.loopbackIPv4, port);
  }
}
