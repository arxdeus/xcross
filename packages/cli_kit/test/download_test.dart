import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:test/test.dart';

Future<List<String>> _captureAsync(Future<void> Function() body) async {
  final sink = _LineCaptureStdout();
  await IOOverrides.runZoned(
    () => runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => sink.writeln(line),
      ),
    ),
    stdout: () => sink,
    stderr: () => sink,
  );
  return sink.lines;
}

final class _LineCaptureStdout implements Stdout {
  final _lines = <String>[];
  final _buffer = StringBuffer();

  List<String> get lines {
    final tail = _buffer.toString();
    if (tail.isNotEmpty) {
      _lines.add(tail);
      _buffer.clear();
    }
    return List.unmodifiable(_lines);
  }

  void _record(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final parts = normalized.split('\n');
    _buffer.write(parts.removeAt(0));
    for (final part in parts) {
      _lines.add(_buffer.toString());
      _buffer
        ..clear()
        ..write(part);
    }
  }

  @override
  Encoding encoding = systemEncoding;

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  int get terminalColumns => 80;

  @override
  int get terminalLines => 24;

  @override
  void write(Object? object) => _record('$object');

  @override
  void writeln([Object? object = '']) => _record('$object\n');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _record(objects.join(separator));

  @override
  void writeCharCode(int charCode) => _record(String.fromCharCode(charCode));

  @override
  void add(List<int> data) => _record(encoding.decode(data));

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}

  @override
  void noSuchMethod(Invocation invocation) {}
}

void main() {
  test(
    'download progress is marked failed when writing the destination fails',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        request.response.headers.contentLength = 5;
        request.response.write('hello');
        await request.response.close();
      });

      final temp = await Directory.systemTemp.createTemp('download-test-');
      addTearDown(() async {
        if (temp.existsSync()) {
          await temp.delete(recursive: true);
        }
      });
      final destination = File(temp.path);

      final lines = await _captureAsync(() async {
        await expectLater(
          () => Downloader.downloadToFile(
            'http://${server.address.host}:${server.port}/file.txt',
            destination,
            label: 'file.txt',
          ),
          throwsA(isA<FileSystemException>()),
        );
      });

      expect(lines, ['file.txt']);
    },
  );
}
