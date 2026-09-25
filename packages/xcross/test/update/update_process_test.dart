import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/internal/update_process.dart';

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
    'missing required executable becomes an actionable XcrossError',
    () async {
      const executable = 'xcross-guaranteed-missing-update-executable';

      await expectLater(
        () => runUpdateProcess(executable, const []),
        throwsA(
          isA<XcrossError>()
              .having((error) => error.message, 'message', contains(executable))
              .having((error) => error.message, 'message', contains('PATH')),
        ),
      );
    },
  );

  for (final extension in ['bat', 'cmd']) {
    test(
      'preserves encoded ref arguments through Windows .$extension',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'update process batch test-',
        );
        addTearDown(() async {
          if (temp.existsSync()) await temp.delete(recursive: true);
        });
        final script = File(p.join(temp.path, 'emit.$extension'))
          ..writeAsStringSync('@echo off\r\necho %*\r\n');

        const encodedBranch = 'feature%2Fa%2Cb%3Dc';
        final result = await runUpdateProcess(
          script.path,
          [encodedBranch],
          environment: {'2Fa': 'EXPANDED'},
        );

        expect(result.exitCode, 0);
        expect((result.stdout as String).trim(), encodedBranch);
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'preserves the built version through a Windows Dart batch launcher',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'update-process-version-test-',
      );
      addTearDown(() async {
        if (temp.existsSync()) await temp.delete(recursive: true);
      });
      final script = File(p.join(temp.path, 'version.dart'))
        ..writeAsStringSync(
          "void main() => print(Uri.decodeComponent(const String.fromEnvironment('XCROSS_VERSION')));\n",
        );
      final dartBatch = File(p.join(temp.path, 'dart.bat'))
        ..writeAsStringSync(
          '@echo off\r\n"${Platform.resolvedExecutable}" %*\r\n',
        );

      final result = await runUpdateProcess(
        dartBatch.path,
        ['run', '-DXCROSS_VERSION=feature%2Fa%2Cb%3Dc', script.path],
        environment: {'2Fa': 'EXPANDED'},
      );

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect((result.stdout as String).trim(), endsWith('feature/a,b=c'));
    },
    skip: !Platform.isWindows,
  );

  test(
    'streams stdout and stderr into the active step while preserving capture',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'update-process-test-',
      );
      addTearDown(() async {
        if (temp.existsSync()) {
          await temp.delete(recursive: true);
        }
      });
      final script = File(p.join(temp.path, 'emit.dart'))
        ..writeAsStringSync(
          "import 'dart:io';\n"
          'void main() {\n'
          "  stdout.writeln('stdout-line');\n"
          "  stderr.writeln('stderr-line');\n"
          '}\n',
        );

      Log.setVerbose();
      final loggedLines = await _captureAsync(() async {
        final step = Log.beginStep('Streaming process');
        final result = await runUpdateProcess(Platform.resolvedExecutable, [
          'run',
          script.path,
        ]);
        expect(result.stdout, contains('stdout-line'));
        expect(result.stderr, contains('stderr-line'));
        step.done();
      });

      expect(loggedLines, contains(contains('stdout-line')));
      expect(loggedLines, contains(contains('stderr-line')));
    },
  );
}
