import 'dart:async';
import 'dart:io';

import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/gdb_remote_client.dart';
import 'package:test/test.dart';

/// ASCII `$` — start-of-packet sentinel (mirrors the production wire format).
const _packetStart = 0x24;

/// ASCII `#` — end-of-payload / checksum separator.
const _packetEnd = 0x23;

/// Builds a `$payload#cc` GDB-remote frame the same way [GdbRemoteClient]
/// computes its checksum, so tests never hardcode magic checksum bytes.
String _frame(String payload) {
  var sum = 0;
  for (final unit in payload.codeUnits) {
    sum = (sum + unit) & 0xff;
  }
  final checksum = sum.toRadixString(16).padLeft(2, '0');
  return '\$$payload#$checksum';
}

/// Yields each complete `$payload#cc` frame received on the "device" side of
/// [socket]. If [rawBytes] is given, every raw byte seen — including bytes
/// before the first frame, such as the unframed `+` no-ack primer — is
/// appended to it.
///
/// Built on a plain [socket.listen] rather than an `async*` passthrough:
/// cancelling a subscription to an `async*` stream while it is suspended mid
/// `await for` on a [Socket] never completes on this SDK, which would hang
/// every test's teardown.
Stream<String> _incomingFrames(Socket socket, {List<int>? rawBytes}) {
  final controller = StreamController<String>();
  final buffer = <int>[];
  final sub = socket.listen(
    (chunk) {
      rawBytes?.addAll(chunk);
      buffer.addAll(chunk);
      while (true) {
        final start = buffer.indexOf(_packetStart);
        if (start < 0) {
          buffer.clear();
          break;
        }
        if (start > 0) buffer.removeRange(0, start);
        final hash = buffer.indexOf(_packetEnd);
        if (hash < 0 || buffer.length < hash + 3) break;
        controller.add(String.fromCharCodes(buffer.sublist(0, hash + 3)));
        buffer.removeRange(0, hash + 3);
      }
    },
    onDone: controller.close,
    onError: controller.addError,
  );
  controller.onCancel = sub.cancel;
  return controller.stream;
}

void main() {
  _stopSignalTests();
  // Pins the checksum format against a hand-computed value, independent of
  // the _frame() helper above — a shared bug in both would otherwise pass.
  test(
    '_frame helper matches the GDB-remote checksum by hand: sum("c")=99=0x63',
    () {
      expect(_frame('c'), r'$c#63');
    },
  );

  group('GdbReplyPacket', () {
    test('decodes hex-encoded stdout bytes', () {
      const packet = GdbReplyPacket(GdbReply.stdout, 'O48656c6c6f');
      expect(packet.stdoutBytes, [72, 101, 108, 108, 111]);
    });

    // Regression check: the hex-decode loop must stop cleanly on a trailing
    // odd character instead of pairing it with garbage or throwing.
    test('truncates an odd-length hex tail instead of throwing', () {
      const packet = GdbReplyPacket(GdbReply.stdout, 'O48656c6c6');
      expect(packet.stdoutBytes, [72, 101, 108, 108]);
    });

    test('skips an invalid hex digit pair instead of throwing', () {
      const packet = GdbReplyPacket(GdbReply.stdout, 'OZZ');
      expect(packet.stdoutBytes, isEmpty);
    });

    test('empty payload after the O prefix decodes to no bytes', () {
      const packet = GdbReplyPacket(GdbReply.stdout, 'O');
      expect(packet.stdoutBytes, isEmpty);
    });
  });

  group('GdbRemoteClient', () {
    late ServerSocket device;

    setUp(() async {
      device = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await device.close();
    });

    /// Connects a fresh [GdbRemoteClient] to [device] and returns it
    /// alongside the server-side socket for the accepted connection.
    Future<(GdbRemoteClient, Socket)> connectClient() async {
      final client = GdbRemoteClient(
        host: device.address.address,
        port: device.port,
      );
      addTearDown(client.close);
      final acceptFuture = device.first;
      await client.connect();
      final socket = await acceptFuture.timeout(const Duration(seconds: 2));
      addTearDown(socket.close);
      return (client, socket);
    }

    test('start() sends the no-ack handshake and completes', () async {
      final (client, socket) = await connectClient();

      final rawBytes = <int>[];
      final requests = <String>[];
      final sub = _incomingFrames(socket, rawBytes: rawBytes).listen((frame) {
        requests.add(frame);
        socket.add(_frame('OK').codeUnits);
      });
      addTearDown(sub.cancel);

      await client.start().timeout(const Duration(seconds: 2));

      // Unframed no-ack primer must be the very first thing sent.
      expect(rawBytes.first, '+'.codeUnitAt(0));
      expect(requests, isNotEmpty);
      expect(requests.first, _frame('QStartNoAckMode'));
    });

    test('attach() resolves on a T/S stop reply', () async {
      final (client, socket) = await connectClient();

      final requests = <String>[];
      final sub = _incomingFrames(socket).listen((frame) {
        requests.add(frame);
        socket.add(_frame('T05').codeUnits);
      });
      addTearDown(sub.cancel);

      final reply = await client
          .attach(1234)
          .timeout(const Duration(seconds: 2));
      expect(reply, 'T05');
      expect(requests.single, startsWith(r'$vAttach;'));
    });

    test(
      'attach() throws TunnelError when the peer rejects the request',
      () async {
        final (client, socket) = await connectClient();

        final sub = _incomingFrames(socket).listen((_) {
          socket.add(_frame('E01').codeUnits);
        });
        addTearDown(sub.cancel);

        await expectLater(
          client.attach(1234).timeout(const Duration(seconds: 2)),
          throwsA(
            isA<TunnelError>().having(
              (e) => e.message,
              'message',
              contains('vAttach rejected'),
            ),
          ),
        );
      },
    );

    test('resume() sends a bare c frame with no reply expected', () async {
      final (client, socket) = await connectClient();

      final firstFrame = _incomingFrames(socket).first;
      await client.resume();

      expect(await firstFrame.timeout(const Duration(seconds: 2)), _frame('c'));
    });

    test('replies stream classifies unsolicited packets', () async {
      final (client, socket) = await connectClient();

      final sub = _incomingFrames(socket).listen((_) {
        socket.add(_frame('OK').codeUnits);
      });
      addTearDown(sub.cancel);
      await client.start().timeout(const Duration(seconds: 2));

      final eventsFuture = client.replies.take(5).toList();
      socket
        ..add(_frame('O48656c6c6f').codeUnits)
        ..add(_frame('W00').codeUnits)
        ..add(_frame('T05').codeUnits)
        ..add(_frame('X09').codeUnits)
        ..add(_frame('').codeUnits);

      final events = await eventsFuture.timeout(const Duration(seconds: 2));

      expect(events[0].type, GdbReply.stdout);
      expect(events[0].payload, 'O48656c6c6f');
      expect(events[0].stdoutBytes, 'Hello'.codeUnits);
      expect(events[1].type, GdbReply.exited);
      expect(events[1].payload, 'W00');
      expect(events[2].type, GdbReply.stopped);
      expect(events[2].payload, 'T05');
      expect(events[3].type, GdbReply.terminated);
      expect(events[3].payload, 'X09');
      expect(events[4].type, GdbReply.other);
      expect(events[4].payload, '');
    });

    test(
      'a packet split across two socket writes is still parsed (buffering)',
      () async {
        final (client, socket) = await connectClient();

        final eventFuture = client.replies.first;

        final frame = _frame('O48656c6c6f');
        final mid = frame.length ~/ 2;
        socket.add(frame.substring(0, mid).codeUnits);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        socket.add(frame.substring(mid).codeUnits);

        final event = await eventFuture.timeout(const Duration(seconds: 2));
        expect(event.type, GdbReply.stdout);
        expect(event.payload, 'O48656c6c6f');
      },
    );

    test('leading garbage before the dollar sign is discarded', () async {
      final (client, socket) = await connectClient();

      // Garbage bytes never produce a dispatched packet at all (they're
      // dropped while scanning for the next '$'), so there is no race to
      // guard against a second event — just await the one valid frame that
      // follows, deterministically, instead of a fixed sleep-then-assert.
      final eventFuture = client.replies.first;
      socket.add('+not a real packet'.codeUnits);
      socket.add(_frame('OK').codeUnits);

      final event = await eventFuture.timeout(const Duration(seconds: 2));
      expect(event.payload, 'OK');
    });

    test(
      'close() is safe to call twice and stops the replies stream',
      () async {
        final (client, _) = await connectClient();

        await client.close();
        await client.close();

        final events = await client.replies.toList().timeout(
          const Duration(seconds: 2),
        );
        expect(events, isEmpty);
      },
    );
  });
}

void _stopSignalTests() {
  group('GdbReplyPacket stop signals', () {
    // A crashing iOS app reports through a T-packet ("T0b..." = SIGSEGV),
    // never through W/X, so this decoding is what makes a crash visible
    // instead of looking like a silent hang.
    test('decodes SIGSEGV from a T packet', () {
      const packet = GdbReplyPacket(GdbReply.stopped, 'T0bthread:1;name:main;');
      expect(packet.stopSignal, 11);
      expect(packet.stopDescription, contains('SIGSEGV'));
      expect(packet.isFatalStop, isTrue);
    });

    test('decodes SIGABRT', () {
      const packet = GdbReplyPacket(GdbReply.stopped, 'T06thread:1;');
      expect(packet.stopSignal, 6);
      expect(packet.isFatalStop, isTrue);
    });

    test('does not treat SIGTRAP as a crash', () {
      const packet = GdbReplyPacket(GdbReply.stopped, 'T05thread:1;');
      expect(packet.stopSignal, 5);
      expect(packet.isFatalStop, isFalse);
    });

    test('ignores non-stop packets', () {
      const packet = GdbReplyPacket(GdbReply.stdout, 'O68690a');
      expect(packet.stopSignal, isNull);
      expect(packet.isFatalStop, isFalse);
    });
  });
}
