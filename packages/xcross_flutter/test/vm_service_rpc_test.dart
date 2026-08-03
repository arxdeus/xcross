import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross_flutter/src/errors.dart';
import 'package:xcross_flutter/src/hot_reload/dart_vm_service_client.dart';

/// The VM Service socket carries three message shapes, and the client has to
/// tell them apart: a notification (method, no id), a request the VM makes OF
/// US (method + id), and a reply to one of our own calls (id, no method).
///
/// Getting that wrong is silent — an inbound `compileExpression` looked like an
/// unmatched reply and was dropped, so every `evaluate` hung or failed, and
/// DevTools then reported a debug build as "profile" and disabled the Inspector.
void main() {
  late HttpServer server;
  late DartVmServiceClient client;
  late Future<WebSocket> socket;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    socket = server.first.then(WebSocketTransformer.upgrade);
    client = DartVmServiceClient();
    await client.connect(Uri.parse('ws://127.0.0.1:${server.port}/ws'));
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  /// Reads frames from the peer, auto-answering our `registerService` call so
  /// tests can get straight to the inbound request.
  Stream<Map<String, Object?>> peerFrames(WebSocket ws) => ws
      .map((raw) => jsonDecode(raw as String) as Map<String, Object?>)
      .where((frame) {
        if (frame['method'] == 'registerService') {
          ws.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {'type': 'Success'},
            }),
          );
          return false;
        }
        return true;
      });

  test('registers a service and answers the VM calling back into it', () async {
    final ws = await socket;
    final frames = peerFrames(ws).asBroadcastStream();

    // Subscribe before registering: the auto-answer above only runs while the
    // pipeline has a listener, and registerService awaits that reply.
    final replyFrame = frames.first;

    Map<String, Object?>? received;
    await client.registerService('compileExpression', 'xcross', (params) async {
      received = params;
      return {
        'type': 'Success',
        'result': {
          'kernelBytes': base64Encode([1, 2, 3]),
        },
      };
    });

    // A string id on purpose: JSON-RPC ids need not be ints, and assuming so is
    // how the reply gets mis-routed.
    ws.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 'vm-1',
        'method': 'compileExpression',
        'params': {'expression': 'Platform.isAndroid', 'isStatic': false},
      }),
    );

    final reply = await replyFrame.timeout(const Duration(seconds: 5));
    expect(reply['id'], 'vm-1');
    expect(reply['jsonrpc'], '2.0');
    expect(reply['type'], 'Success');
    expect((reply['result']! as Map)['kernelBytes'], base64Encode([1, 2, 3]));
    expect(received?['expression'], 'Platform.isAndroid');
  });

  test(
    'reports a compile failure as an error response, never silence',
    () async {
      final ws = await socket;
      final frames = peerFrames(ws).asBroadcastStream();

      final replyFrame = frames.first;
      await client.registerService(
        'compileExpression',
        'xcross',
        (params) async => throw StateError('no such library'),
      );

      ws.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 7,
          'method': 'compileExpression',
          'params': <String, Object?>{},
        }),
      );

      final reply = await replyFrame.timeout(const Duration(seconds: 5));
      final error = reply['error']! as Map<String, Object?>;
      // 113 = kExpressionCompilationError, which the VM forwards to the caller.
      expect(error['code'], 113);
      expect((error['data']! as Map)['details'], contains('no such library'));
    },
  );

  test(
    'answers an unregistered method rather than leaving the VM waiting',
    () async {
      final ws = await socket;
      final frames = peerFrames(ws).asBroadcastStream();

      ws.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 9,
          'method': 'somethingElse',
          'params': <String, Object?>{},
        }),
      );

      final reply = await frames.first.timeout(const Duration(seconds: 5));
      expect((reply['error']! as Map)['code'], -32601);
    },
  );

  test(
    'still routes notifications and replies (classification regression)',
    () async {
      final ws = await socket;
      final frames = peerFrames(ws).asBroadcastStream();

      // A notification must reach `events`, not be mistaken for a request.
      final event = client.events.first;
      ws.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'streamNotify',
          'params': {
            'streamId': 'Stdout',
            'event': {
              'kind': 'WriteEvent',
              'bytes': base64Encode([65]),
            },
          },
        }),
      );
      expect(
        (await event.timeout(const Duration(seconds: 5)))['streamId'],
        'Stdout',
      );

      // And an ordinary reply must still resolve our own call.
      final pending = client.call('getVM');
      final request = await frames.first.timeout(const Duration(seconds: 5));
      ws.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': {'type': 'VM', 'name': 'probe'},
        }),
      );
      expect(
        (await pending.timeout(const Duration(seconds: 5)))['name'],
        'probe',
      );
    },
  );

  test('a call with no reply times out with an FlutterBuildError', () async {
    // Peer never answers 'someMethodNobodyAnswers' on purpose.
    await expectLater(
      client.call(
        'someMethodNobodyAnswers',
        timeout: const Duration(milliseconds: 150),
      ),
      throwsA(
        isA<FlutterBuildError>().having(
          (e) => e.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });

  test(
    'waitForEvent resolves to an empty map on timeout rather than throwing',
    () async {
      final result = await client.waitForEvent(
        'NoSuchKindEver',
        timeout: const Duration(milliseconds: 150),
      );
      expect(result, isEmpty);
    },
  );

  test(
    'streamListen swallows a peer error, e.g. an already-subscribed stream',
    () async {
      final ws = await socket;
      final requestFrame = ws
          .map((raw) => jsonDecode(raw as String) as Map<String, Object?>)
          .first;

      final result = client.streamListen('Isolate');

      final frame = await requestFrame.timeout(const Duration(seconds: 5));
      expect(frame['method'], 'streamListen');
      ws.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': frame['id'],
          'error': {'code': 103, 'message': 'Stream already subscribed'},
        }),
      );

      await expectLater(result, completes);
    },
  );
}
