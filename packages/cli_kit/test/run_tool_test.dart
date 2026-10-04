import 'dart:async';
import 'dart:io';

import 'package:cli_kit/composition/native_host.dart';
import 'package:cli_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_log_output.dart';
import 'support/test_process_io.dart';

List<String> _capture(void Function() body) {
  final lines = <String>[];
  runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}

Future<List<String>> _captureAsync(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  final io = TestProcessIo();
  tearDownAll(io.close);
  final log = Log(output: TestLogOutput(emit: print));
  final nativeHost = detectPlatformHost();
  late ProcessRunner<PlatformHostInterface> runner;
  setUp(
    () => runner = ProcessRunner(
      nativeHost,
      log: log,
      stdinStream: io.input,
      stdoutSink: io.output,
      stderrSink: io.error,
    ),
  );

  late Directory temp;

  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('xcross_run_tool_test_');
  });

  tearDownAll(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// A real subprocess that writes [text] and exits with [exitCode] — the
  /// shape of every build tool runTool drives.
  List<String> script(String name, String text, {int exitCode = 0}) {
    final file = File(p.join(temp.path, '$name.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'void main() {\n'
        "  stdout.writeln('$text');\n"
        '  exit($exitCode);\n'
        '}\n',
      );
    return [file.path];
  }

  group('log.activeStep', () {
    test('is null when no phase is running', () {
      log.stopStep();
      expect(log.activeStep, isNull);
    });

    // runTool reaches for this instead of threading a Step through every
    // builder, so a closed phase must not leave a dangling tail behind.
    test('tracks the running phase and clears on close', () {
      _capture(() {
        final step = log.beginStep('Building');
        expect(log.activeStep, same(step));
        step.done();
        expect(log.activeStep, isNull);
      });
    });
  });

  group('runner.runTool', () {
    // The whole point: Gradle and konanc print hundreds of lines, and a
    // successful build should show nothing but its own phase.
    test('keeps a successful tool quiet', () async {
      final lines = await _captureAsync(() async {
        final step = log.beginStep('Compiling');
        await runner.runTool(
          Platform.resolvedExecutable,
          script('ok', '> Task :shared:compileKotlinIosArm64'),
        );
        step.done();
      });
      expect(lines.join('\n'), isNot(contains('compileKotlinIosArm64')));
    });

    // Quiet on success is only acceptable if failure is loud: the captured
    // output is the only surviving copy of why the build broke.
    test('quotes the output when the tool fails', () async {
      await _captureAsync(() async {
        final step = log.beginStep('Compiling');
        await expectLater(
          runner.runTool(
            Platform.resolvedExecutable,
            script('bad', 'e: Unresolved reference', exitCode: 1),
          ),
          throwsA(
            isA<CliError>().having(
              (error) => error.message,
              'message',
              contains('Unresolved reference'),
            ),
          ),
        );
        step.fail();
      });
    });

    test('runs with no phase on screen', () async {
      log.stopStep();
      await _captureAsync(
        () => runner.runTool(
          Platform.resolvedExecutable,
          script('bare', 'no phase'),
        ),
      );
    });
  });
}
