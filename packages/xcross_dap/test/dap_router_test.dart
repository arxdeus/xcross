import 'dart:async';

import 'package:dds/dap.dart';
import 'package:test/test.dart';
import 'package:xcross_dap/src/dap_router.dart';

void main() {
  test('DapFrameParser splits Content-Length frames across chunks', () {
    final parser = DapFrameParser();
    final msg = encodeDapFrame({
      'seq': 1,
      'type': 'request',
      'command': 'initialize',
      'arguments': {'adapterID': 'dart'},
    });

    final mid = msg.length ~/ 2;
    expect(parser.push(msg.sublist(0, mid)), isEmpty);

    final frames = parser.push(msg.sublist(mid));
    expect(frames, hasLength(1));
    expect(frames.single.json['command'], 'initialize');
    expect(frames.single.raw, msg);
  });

  test(
    'DapResponseFilter drops answered responses and one initialized event',
    () async {
      final out = StreamController<List<int>>();
      final received = <Map<String, Object?>>[];
      out.stream.listen((chunk) {
        final parser = DapFrameParser();
        for (final frame in parser.push(chunk)) {
          received.add(frame.json);
        }
      });

      final filter = DapResponseFilter(out, {1, 2});
      filter.add(
        encodeDapFrame({
          'seq': 10,
          'type': 'response',
          'request_seq': 1,
          'success': true,
          'command': 'initialize',
        }),
      );
      filter.add(
        encodeDapFrame({
          'seq': 11,
          'type': 'event',
          'event': 'initialized',
          'body': <String, Object?>{},
        }),
      );
      filter.add(
        encodeDapFrame({
          'seq': 12,
          'type': 'response',
          'request_seq': 3,
          'success': true,
          'command': 'launch',
        }),
      );
      filter.add(
        encodeDapFrame({
          'seq': 13,
          'type': 'event',
          'event': 'output',
          'body': {'output': 'hi'},
        }),
      );
      await filter.close();
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(2));
      expect(received[0]['command'], 'launch');
      expect(received[1]['event'], 'output');
    },
  );

  test('runDapSession with xcross:true starts the xcross adapter', () async {
    final inbound = StreamController<List<int>>();
    final outbound = StreamController<List<int>>();
    ByteStreamServerChannel? started;

    final session = runDapSession(
      startXcross: (channel) {
        started = channel;
        // Don't run a real adapter — just close once launch is replayed.
        channel.listen((_) {}, onDone: channel.close);
      },
      input: inbound.stream,
      output: outbound,
    );

    void send(Map<String, Object?> msg) => inbound.add(encodeDapFrame(msg));

    send({
      'seq': 1,
      'type': 'request',
      'command': 'initialize',
      'arguments': {'adapterID': 'dart'},
    });
    send({'seq': 2, 'type': 'request', 'command': 'configurationDone'});
    send({
      'seq': 3,
      'type': 'request',
      'command': 'launch',
      'arguments': {'program': 'lib/main.dart', 'xcross': true},
    });
    await inbound.close();
    await session;

    expect(started, isNotNull);
  });
}
