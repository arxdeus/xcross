import 'dart:io';

import 'package:dart_mobile_device/src/tunnel/tunnel_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('TunneldLogTail', () {
    late Directory dir;
    late String logPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('xcross_tunneld_tail');
      logPath = p.join(dir.path, 'tunneld.log');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('missing file reads as empty', () {
      final tail = TunneldLogTail.start(path: logPath);
      expect(tail.readNew(), isEmpty);
      expect(tail.seen, isEmpty);
    });

    test('starts at the current end, not the beginning', () {
      File(logPath).writeAsStringSync('old daemon output\n');
      final tail = TunneldLogTail.start(path: logPath);
      expect(tail.readNew(), isEmpty);
      File(logPath).writeAsStringSync('new line\n', mode: FileMode.append);
      expect(tail.readNew(), 'new line\n');
    });

    test('accumulates chunks into seen', () {
      final tail = TunneldLogTail.start(path: logPath);
      File(logPath).writeAsStringSync('a\n');
      expect(tail.readNew(), 'a\n');
      File(logPath).writeAsStringSync('b\n', mode: FileMode.append);
      expect(tail.readNew(), 'b\n');
      expect(tail.seen, 'a\nb\n');
    });

    test('restarts from zero after truncation', () {
      File(logPath).writeAsStringSync('a long first generation\n');
      final tail = TunneldLogTail.start(path: logPath);
      File(logPath).writeAsStringSync('tiny\n'); // Shorter than the offset.
      expect(tail.readNew(), 'tiny\n');
    });

    test('detects the QUIC-unsupported signature', () {
      final tail = TunneldLogTail.start(path: logPath);
      File(logPath).writeAsStringSync(
        'WARNING [start-tunnel-task-wifi-192.168.1.170] '
        'QuicProtocolNotSupportedError: iOS 18.2+ removed QUIC protocol '
        'support. Use TCP instead (requires python3.13+)\n',
      );
      tail.readNew();
      expect(tail.sawQuicUnsupported, isTrue);
    });

    test('no false QUIC positive on ordinary output', () {
      final tail = TunneldLogTail.start(path: logPath);
      File(logPath).writeAsStringSync('INFO: Uvicorn running\n');
      tail.readNew();
      expect(tail.sawQuicUnsupported, isFalse);
    });
  });
}
