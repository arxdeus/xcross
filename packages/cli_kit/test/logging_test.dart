import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:test/test.dart';

import 'support/log_output.dart';

void main() {
  late RecordingLogOutput output;
  late Log log;
  setUp(() {
    output = RecordingLogOutput();
    log = Log(output: output);
  });
  tearDown(() => log.stopStep());
  test('a step announces its start, then reports once', () {
    final lines = output.lines;
    final step = log.beginStep('Building');
    step.done();
    step.done();
    expect(lines, hasLength(2));
    expect(lines.first, endsWith('Building…'));
    expect(lines.last, contains('Building'));
  });

  test('failure reports ✗', () {
    final lines = output.lines;
    log.beginStep('Building').fail();
    expect(lines.last, contains('Building'));
  });

  test('an interrupting status line does not swallow the ✓', () {
    final lines = output.lines;
    final step = log.beginStep('Building');
    log.logInfo('vm-service:', 'ws://127.0.0.1:1234/ws');
    step.done();
    expect(lines, hasLength(3));
    expect(lines[1], contains('vm-service: '));
    expect(lines.last, contains('Building'));
  });

  test('logStep rethrows and marks the step failed', () async {
    final lines = output.lines;
    await expectLater(
      log.logStep<void>('Compiling', () async => throw StateError('boom')),
      throwsStateError,
    );
    expect(lines.last, contains('Compiling'));
  });

  test('trace output is suppressed until --verbose', () {
    log.logTrace('clang -c foo.m');
    expect(output.lines, isEmpty);
  });

  test('sessions isolate verbosity and active steps', () {
    final otherOutput = RecordingLogOutput();
    final other = Log(output: otherOutput);
    final first = log.beginStep('First');
    final second = other.beginStep('Second');
    log.setVerbose();
    expect(log.isVerbose, isTrue);
    expect(other.isVerbose, isFalse);
    expect(log.activeStep, isNull);
    expect(other.activeStep, same(second));
    log.logTrace('visible');
    other.logTrace('hidden');
    first.done();
    expect(other.activeStep, same(second));
    second.done();
    expect(output.lines, contains('visible'));
    expect(otherOutput.lines.join(), isNot(contains('hidden')));
  });

  test(
    'spinner sessions repaint independently and stopping one preserves the other',
    () async {
      final firstOutput = RecordingLogOutput(supportsAnsi: true);
      final secondOutput = RecordingLogOutput(supportsAnsi: true);
      final firstLog = Log(output: firstOutput);
      final secondLog = Log(output: secondOutput);
      final first = firstLog.beginStep('First');
      final second = secondLog.beginStep('Second');
      firstLog.stopStep();
      final firstCount = firstOutput.writes.length;
      final secondCount = secondOutput.writes.length;
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(firstOutput.writes, hasLength(firstCount));
      expect(secondOutput.writes.length, greaterThan(secondCount));
      expect(secondLog.activeStep, same(second));
      first.done();
      expect(secondLog.activeStep, same(second));
      second.done();
      expect(secondLog.activeStep, isNull);
    },
  );

  test('verbose tail normalizes split chunks and suppresses closed writes', () {
    log.setVerbose();
    final step = log.beginStep('Build');
    step.log('one\r\ntw');
    step.log('o\rthree\n');
    expect(output.lines, containsAllInOrder(['one', 'two', 'three']));
    step.done();
    final count = output.lines.length;
    step.log('ignored\n');
    step.fail();
    expect(output.lines, hasLength(count));
  });

  test('spinner truncates tail and cleanup cancels redraw timers', () async {
    final terminal = RecordingLogOutput(
      supportsAnsi: true,
      terminalColumns: 16,
    );
    final fancy = Log(output: terminal);
    final step = fancy.beginStep('Building');
    step.log('old\na\nb\nc\n123456789012345');
    expect(terminal.writes.last, isNot(contains('old')));
    expect(terminal.writes.last, contains('123456789…'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(terminal.writes.length, greaterThan(2));
    fancy.logError('broken');
    expect(fancy.activeStep, isNull);
    expect(terminal.errors.single, contains('✗'));
    final count = terminal.writes.length;
    step.log('late\n');
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(terminal.writes, hasLength(count));
    step.fail();
    step.fail();
    expect(terminal.lines, hasLength(1));
  });

  test(
    'asynchronous failure clears spinner and preserves original error',
    () async {
      final terminal = RecordingLogOutput(supportsAnsi: true);
      final fancy = Log(output: terminal);
      final error = StateError('boom');
      await expectLater(
        fancy.logStep<void>('Compile', () async => throw error),
        throwsA(same(error)),
      );
      expect(fancy.activeStep, isNull);
      expect(terminal.lines.single, contains('✗'));
      final count = terminal.writes.length;
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(terminal.writes, hasLength(count));
    },
  );

  test('explicit stream sink routes lines, errors and raw output', () async {
    final outBytes = <int>[];
    final errBytes = <int>[];
    final outController = StreamController<List<int>>();
    final errController = StreamController<List<int>>();
    addTearDown(outController.close);
    addTearDown(errController.close);
    outController.stream.listen(outBytes.addAll);
    errController.stream.listen(errBytes.addAll);
    final out = IOSink(outController.sink);
    final err = IOSink(errController.sink);
    final sink = StreamLogOutput(
      stdout: out,
      stderr: err,
      supportsAnsi: false,
      terminalColumns: () => 90,
    );
    sink.stdout('line');
    sink.stderr('error');
    sink.write('raw');
    await out.close();
    await err.close();
    expect(utf8.decode(outBytes), 'line\nraw');
    expect(utf8.decode(errBytes), 'error\n');
    expect(sink.terminalColumns, 90);
  });

  test('failed initial render leaves no unreachable periodic timer', () async {
    final output = ThrowingLogOutput(supportsAnsi: true, failWriteAt: 1);
    final log = Log(output: output);
    expect(() => log.beginStep('Build'), throwsA(same(output.error)));
    expect(log.activeStep, isNull);
    log.stopStep();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(output.writeAttempts, 1);
  });

  test('failed periodic render suspends and cancels future ticks', () async {
    final output = ThrowingLogOutput(supportsAnsi: true, failWriteAt: 2);
    final log = Log(output: output);
    final step = log.beginStep('Build');
    await Future<void>.delayed(const Duration(milliseconds: 260));
    expect(output.writeAttempts, 2);
    expect(log.activeStep, isNull);
    step.log('late\n');
    step.done();
    expect(output.writeAttempts, 2);
  });

  test('failed diagnostics preserve body error and original stack', () async {
    final output = ThrowingLogOutput(failStdoutAt: 2);
    final log = Log(output: output);
    final error = StateError('body failed');
    final stack = StackTrace.fromString('original body stack');
    try {
      await log.logStep<void>('Build', () => Future<void>.error(error, stack));
      fail('must throw');
    } on Object catch (actual, actualStack) {
      expect(actual, same(error));
      expect(actualStack.toString(), stack.toString());
    }
    expect(log.activeStep, isNull);
    expect(output.stdoutAttempts, 2);
  });

  group('renderBlock', () {
    test('first paint does not move the cursor up', () {
      final out = Step.renderBlock(head: 'x', tail: [], previousRows: 0);
      expect(out, isNot(matches(RegExp(r'\x1B\[\d+A'))));
      expect('\n'.allMatches(out), hasLength(1));
    });

    test('repaint rewinds by the previous row count', () {
      final first = Step.renderBlock(
        head: 'x',
        tail: ['a', 'b'],
        previousRows: 0,
      );
      expect('\n'.allMatches(first), hasLength(3));
      final second = Step.renderBlock(
        head: 'x',
        tail: ['a', 'b'],
        previousRows: 3,
      );
      expect(second, startsWith('\x1B[3A'));
      expect('\n'.allMatches(second), hasLength(3));
    });

    test('every row clears its own leftovers', () {
      final out = Step.renderBlock(head: 'x', tail: ['a'], previousRows: 2);
      expect('\x1B[K'.allMatches(out), hasLength(2));
    });
  });
}
