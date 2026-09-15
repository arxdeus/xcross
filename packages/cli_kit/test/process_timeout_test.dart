import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:test/test.dart';

void main() {
  late Directory scripts;

  setUpAll(() => scripts = Directory.systemTemp.createTempSync('xc-timeout-'));
  tearDownAll(() => scripts.deleteSync(recursive: true));

  /// Writes [body] as a Dart program and returns the arguments that run it.
  List<String> program(String name, String body) {
    final file = File('${scripts.path}${Platform.pathSeparator}$name.dart')
      ..writeAsStringSync(body);
    return [file.path];
  }

  group('ProcessRunner.run timeout', () {
    // The hang this guards against is a child that never exits and never
    // writes: a credential prompt reading a pipe nobody answers.
    test('kills a child that never exits and reports it', () async {
      final started = Stopwatch()..start();
      final result = await ProcessRunner.run(
        Platform.resolvedExecutable,
        program(
          'hang',
          'import "dart:io";\n'
              'import "dart:async";\n'
              'void main() {\n'
              '  stdin.listen((_) {});\n'
              '  Timer(const Duration(minutes: 10), () {});\n'
              '}\n',
        ),
        timeout: const Duration(seconds: 10),
      );
      started.stop();

      expect(result.timedOut, isTrue);
      expect(
        started.elapsed,
        lessThan(const Duration(minutes: 2)),
        reason: 'the child must be killed, not waited on',
      );
    });

    test('leaves a fast command untouched', () async {
      final result = await ProcessRunner.run(
        Platform.resolvedExecutable,
        program('ok', 'void main() { print("ok"); }\n'),
        timeout: const Duration(minutes: 5),
      );

      expect(result.timedOut, isFalse);
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'ok');
    });

    test('captures output of a command that exits non-zero', () async {
      final result = await ProcessRunner.run(
        Platform.resolvedExecutable,
        program(
          'boom',
          'import "dart:io";\n'
              'void main() { stderr.write("boom"); exit(3); }\n',
        ),
        timeout: const Duration(minutes: 5),
      );

      expect(result.timedOut, isFalse);
      expect(result.exitCode, 3);
      expect(result.stderr, contains('boom'));
    });

    test('runChecked reports a timeout as a timeout, not a failed command',
        () async {
      await expectLater(
        ProcessRunner.runChecked(
          Platform.resolvedExecutable,
          program(
            'hang-checked',
            'import "dart:io";\n'
                'import "dart:async";\n'
                'void main() {\n'
                '  stdin.listen((_) {});\n'
                '  Timer(const Duration(minutes: 10), () {});\n'
                '}\n',
          ),
          timeout: const Duration(seconds: 10),
        ),
        throwsA(
          isA<CliError>().having(
            (error) => error.toString(),
            'message',
            contains('timed out'),
          ),
        ),
      );
    });

    // `--verbose` routes builds through the inherit-stdio path. That path
    // used to ignore `timeout` outright, so a stalled `swift package resolve`
    // ran unbounded on CI even though the caller had asked for a limit.
    test('applies to inheritStdio, which verbose builds use', () async {
      final started = Stopwatch()..start();
      await expectLater(
        ProcessRunner.runChecked(
          Platform.resolvedExecutable,
          program(
            'hang-inherit',
            'import "dart:io";\n'
                'import "dart:async";\n'
                'void main() {\n'
                '  stdin.listen((_) {});\n'
                '  Timer(const Duration(minutes: 10), () {});\n'
                '}\n',
          ),
          inheritStdio: true,
          timeout: const Duration(seconds: 10),
        ),
        throwsA(
          isA<CliError>().having(
            (error) => error.toString(),
            'message',
            contains('timed out'),
          ),
        ),
      );
      started.stop();
      expect(started.elapsed, lessThan(const Duration(minutes: 2)));
    });
  });
}
