import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('TunneldLogTail', () {
    late Directory dir;
    late String logPath;
    late MappedTailFileSystem fileSystem;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('xcross_tunneld_tail');
      logPath = '/selected/tunneld.log';
      fileSystem = MappedTailFileSystem(
        logPath,
        p.join(dir.path, 'tunneld.log'),
      );
    });

    tearDown(() {
      expect(fileSystem.requests, everyElement(logPath));
      dir.deleteSync(recursive: true);
    });

    test('missing file reads as empty', () {
      final tail = TunneldLogTail.start(path: logPath, fileSystem: fileSystem);
      expect(tail.readNew(), isEmpty);
      expect(tail.seen, isEmpty);
    });

    test('starts at the current end, not the beginning', () {
      fileSystem.file(logPath).writeAsStringSync('old daemon output\n');
      final tail = TunneldLogTail.start(path: logPath, fileSystem: fileSystem);
      expect(tail.readNew(), isEmpty);
      fileSystem
          .file(logPath)
          .writeAsStringSync('new line\n', mode: FileMode.append);
      expect(tail.readNew(), 'new line\n');
    });

    test('accumulates chunks into seen', () {
      final tail = TunneldLogTail.start(path: logPath, fileSystem: fileSystem);
      fileSystem.file(logPath).writeAsStringSync('a\n');
      expect(tail.readNew(), 'a\n');
      fileSystem.file(logPath).writeAsStringSync('b\n', mode: FileMode.append);
      expect(tail.readNew(), 'b\n');
      expect(tail.seen, 'a\nb\n');
    });

    test('restarts from zero after truncation', () {
      fileSystem.file(logPath).writeAsStringSync('a long first generation\n');
      final tail = TunneldLogTail.start(path: logPath, fileSystem: fileSystem);
      fileSystem
          .file(logPath)
          .writeAsStringSync('tiny\n'); // Shorter than the offset.
      expect(tail.readNew(), 'tiny\n');
    });

    test('detects the QUIC-unsupported signature', () {
      final tail = TunneldLogTail.start(path: logPath, fileSystem: fileSystem);
      fileSystem
          .file(logPath)
          .writeAsStringSync(
            'WARNING [start-tunnel-task-wifi-192.168.1.170] '
            'QuicProtocolNotSupportedError: iOS 18.2+ removed QUIC protocol '
            'support. Use TCP instead (requires python3.13+)\n',
          );
      tail.readNew();
      expect(tail.sawQuicUnsupported, isTrue);
    });

    test('no false QUIC positive on ordinary output', () {
      final tail = TunneldLogTail.start(path: logPath, fileSystem: fileSystem);
      fileSystem.file(logPath).writeAsStringSync('INFO: Uvicorn running\n');
      tail.readNew();
      expect(tail.sawQuicUnsupported, isFalse);
    });
  });
}

final class MappedTailFileSystem implements HostFileSystemInterface {
  MappedTailFileSystem(this.logicalPath, this.physicalPath);

  final String logicalPath;
  final String physicalPath;
  final requests = <String>[];

  @override
  File file(String path) {
    requests.add(path);
    if (path != logicalPath) throw StateError('unexpected path: $path');
    return File(physicalPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected filesystem operation');
}
