import 'dart:async';
import 'dart:io';

import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:meta/meta.dart';

@internal
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
      Error.throwWithStackTrace(failure, StackTrace.current);
    }
    await connectReady;
    final endpoint = destination ?? (host: host, port: port);
    final socket = await Socket.connect(
      endpoint.host,
      endpoint.port,
      timeout: timeout,
    );
    return socket;
  }

  @override
  Future<ServerSocket> bindLoopback({int port = 0}) {
    bindings.add(port);
    if (bindFailure case final Object failure) return Future.error(failure);
    return ServerSocket.bind(InternetAddress.loopbackIPv4, port);
  }
}
