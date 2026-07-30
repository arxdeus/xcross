import 'dart:async';

import 'package:test/test.dart';
// ignore: implementation_imports
import 'package:xcross/src/util/logging.dart';

/// Collect everything the logger prints to stdout. Under `dart test` there is
/// no TTY, so spinners are disabled and every line arrives via `print`.
List<String> capture(void Function() body) {
  final lines = <String>[];
  runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  // Without a spinner to watch (piped output, a VS Code debug console,
  // --verbose) a long step must still announce itself, or it looks like a hang.
  test('a step announces its start, then reports once', () {
    final lines = capture(() {
      final step = beginStep('Building');
      step.done();
      step.done(); // double-close must not double-report
    });
    expect(lines, hasLength(2));
    expect(lines.first, startsWith('› Building…'));
    expect(lines.last, startsWith('✓ Building'));
  });

  test('failure reports ✗', () {
    final lines = capture(() => beginStep('Building').fail());
    expect(lines.last, startsWith('✗ Building'));
  });

  test('an interrupting status line does not swallow the ✓', () {
    final lines = capture(() {
      final step = beginStep('Building');
      logInfo('vm-service:', 'ws://127.0.0.1:1234/ws');
      step.done();
    });
    expect(lines, hasLength(3));
    expect(lines[1], contains('vm-service: '));
    expect(lines.last, startsWith('✓ Building'));
  });

  test('logStep rethrows and marks the step failed', () async {
    final lines = <String>[];
    await runZoned(
      () async {
        await expectLater(
          logStep<void>('Compiling', () async => throw StateError('boom')),
          throwsStateError,
        );
      },
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => lines.add(line),
      ),
    );
    expect(lines.last, startsWith('✗ Compiling'));
  });

  test('trace output is suppressed until --verbose', () {
    expect(capture(() => logTrace('clang -c foo.m')), isEmpty);
  });

  group('renderBlock', () {
    // The cursor ends one row below the block, so the next repaint must move
    // up by exactly the row count of the previous one. Getting this wrong
    // smears the spinner down the screen.
    test('first paint does not move the cursor up', () {
      final out = Step.renderBlock(head: 'x', tail: [], previousRows: 0);
      expect(out, isNot(matches(RegExp(r'\x1B\[\d+A'))));
      expect('\n'.allMatches(out), hasLength(1));
    });

    test('repaint rewinds by the previous row count', () {
      final first =
          Step.renderBlock(head: 'x', tail: ['a', 'b'], previousRows: 0);
      expect('\n'.allMatches(first), hasLength(3));
      final second =
          Step.renderBlock(head: 'x', tail: ['a', 'b'], previousRows: 3);
      expect(second, startsWith('\x1B[3A'));
      expect('\n'.allMatches(second), hasLength(3));
    });

    test('every row clears its own leftovers', () {
      final out = Step.renderBlock(head: 'x', tail: ['a'], previousRows: 2);
      expect('\x1B[K'.allMatches(out), hasLength(2));
    });
  });
}
