import 'dart:async';
import 'dart:io';

// ignore: implementation_imports
import 'package:cli_kit/src/errors.dart';
// ignore: implementation_imports
import 'package:cli_kit/src/logging.dart';
// ignore: implementation_imports
import 'package:cli_kit/src/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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

  group('Log.activeStep', () {
    test('is null when no phase is running', () {
      Log.stopStep();
      expect(Log.activeStep, isNull);
    });

    // runTool reaches for this instead of threading a Step through every
    // builder, so a closed phase must not leave a dangling tail behind.
    test('tracks the running phase and clears on close', () {
      _capture(() {
        final step = Log.beginStep('Building');
        expect(Log.activeStep, same(step));
        step.done();
        expect(Log.activeStep, isNull);
      });
    });
  });

  group('ProcessRunner.runTool', () {
    // The whole point: Gradle and konanc print hundreds of lines, and a
    // successful build should show nothing but its own phase.
    test('keeps a successful tool quiet', () async {
      final lines = await _captureAsync(() async {
        final step = Log.beginStep('Compiling');
        await ProcessRunner.runTool(
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
        final step = Log.beginStep('Compiling');
        await expectLater(
          ProcessRunner.runTool(
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
      Log.stopStep();
      await _captureAsync(
        () => ProcessRunner.runTool(
          Platform.resolvedExecutable,
          script('bare', 'no phase'),
        ),
      );
    });
  });
}
