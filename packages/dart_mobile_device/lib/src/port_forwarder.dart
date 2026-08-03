import 'dart:async';
import 'dart:io';
import 'package:cli_kit/cli_kit.dart';


/// Publishes a device TCP port on `127.0.0.1` so tools that cannot use the RSD
/// tunnel address directly can still reach it.
///
/// The VM Service lives on the phone behind an IPv6 tunnel, so its URI is a
/// bracketed IPv6 literal (`ws://[fdxx::1]:12345/ws`). Dart connects to that
/// fine, but DevTools runs in a browser or editor webview, and the URI also
/// travels through the editor's external-URI forwarding — an IPv6 literal
/// survives none of that reliably. A loopback IPv4 port is what `flutter run`
/// hands out, so it is the shape every downstream consumer already handles.
class PortForwarder {
  PortForwarder._(this._server, this._sockets);

  final ServerSocket _server;
  final Set<Socket> _sockets;
  bool _closed = false;

  /// The loopback port to advertise.
  int get localPort => _server.port;

  /// Start forwarding `127.0.0.1:<localPort>` to [deviceHost]:[devicePort].
  static Future<PortForwarder> start({
    required String deviceHost,
    required int devicePort,
  }) async {
    // Port 0: let the OS pick, so two concurrent sessions never collide.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>{};
    final forwarder = PortForwarder._(server, sockets);

    server.listen((client) async {
      if (forwarder._closed) {
        client.destroy();
        return;
      }
      client.setOption(SocketOption.tcpNoDelay, true);
      sockets.add(client);
      final Socket device;
      try {
        // Socket.connect wants a bare address; a bracketed literal never
        // resolves. Callers pass tunnel.address raw today, so this is defensive.
        device = await Socket.connect(
          ProcessRunner.unbracketHost(deviceHost),
          devicePort,
        );
      } on Object catch (e) {
        Log.logWarn('vm-service forward failed: $e');
        sockets.remove(client);
        client.destroy();
        return;
      }
      if (forwarder._closed) {
        sockets.remove(client);
        client.destroy();
        device.destroy();
        return;
      }
      device.setOption(SocketOption.tcpNoDelay, true);
      sockets.add(device);

      /// Copies until [from] reaches EOF, then half-closes [to].
      ///
      /// Closes ONLY [to]: `from`'s sink is the opposite pipe's destination, and
      /// closing it here races that pipe's still-bound `addStream`
      /// ("StreamSink is bound to a stream").
      Future<void> pipe(Socket from, Socket to) async {
        try {
          await to.addStream(from);
          await to.close();
        } on Object catch (_) {
          // Peer vanished mid-copy; the teardown below is the only cleanup.
        }
      }

      try {
        await Future.wait([pipe(client, device), pipe(device, client)]);
      } finally {
        sockets
          ..remove(client)
          ..remove(device);
        client.destroy();
        device.destroy();
      }
    }, onError: (Object e) => Log.logWarn('vm-service forward error: $e'));

    return forwarder;
  }

  /// A listening ServerSocket, or a live forwarded Socket, keeps the Dart event
  /// loop alive — so this must run on every exit path or `xcross flutter run`
  /// never returns.
  Future<void> close() async {
    _closed = true;
    // Destroy live connections before awaiting the listener close. On Windows,
    // a peer that stays attached can otherwise keep ServerSocket.close()
    // pending indefinitely.
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    await _server.close();
  }
}
