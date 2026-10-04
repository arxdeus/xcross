import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/host/shared/cli/native_command_prompt.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/errors/errors.dart';

final class PromptTestInput implements Stdin {
  PromptTestInput({
    required this.events,
    this.terminal = true,
    this.echo = true,
    this.line = false,
    this.value = 'secret',
    this.failures = const {},
  });

  final List<String> events;
  final bool terminal;
  final Set<String> failures;
  bool echo;
  bool line;
  String? value;
  int reads = 0;

  void record(String event) {
    events.add(event);
    if (failures.contains(event)) throw StateError(event);
  }

  @override
  bool get hasTerminal {
    record('terminal');
    return terminal;
  }

  @override
  bool get echoMode {
    record('get echo');
    return echo;
  }

  @override
  set echoMode(bool value) {
    record('echo $value');
    echo = value;
  }

  @override
  bool get lineMode {
    record('get line');
    return line;
  }

  @override
  set lineMode(bool value) {
    record('line $value');
    line = value;
  }

  @override
  String? readLineSync({
    Encoding encoding = systemEncoding,
    bool retainNewlines = false,
  }) {
    reads++;
    record('read');
    return value;
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class PromptTestSink implements StringSink {
  PromptTestSink({required this.events, this.failures = const {}});

  final List<String> events;
  final Set<String> failures;
  final StringBuffer buffer = StringBuffer();

  void record(String event) {
    events.add(event);
    if (failures.contains(event)) throw StateError(event);
  }

  @override
  void write(Object? object) {
    record('write $object');
    buffer.write(object);
  }

  @override
  void writeln([Object? object = '']) {
    record('newline');
    buffer.writeln(object);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);
}

Matcher promptError(String message) =>
    isA<XcrossError>().having((error) => error.message, 'message', message);

void main() {
  test('secret refuses a nonterminal without output or reads', () {
    final events = <String>[];
    final input = PromptTestInput(events: events, terminal: false);
    final sink = PromptTestSink(events: events);
    final prompt = NativeCommandPrompt(input: input, output: sink);
    expect(
      () => prompt.readSecret('Password: ', valueName: 'password'),
      throwsA(promptError('password prompt requires an interactive terminal.')),
    );
    expect(events, ['terminal']);
    expect(input.reads, 0);
    expect(sink.buffer.toString(), isEmpty);
  });

  test(
    'secret writes first, changes modes in order and restores exact modes',
    () {
      final events = <String>[];
      final input = PromptTestInput(events: events, value: '  secret  ');
      final sink = PromptTestSink(events: events);
      final CommandPrompt prompt = NativeCommandPrompt(
        input: input,
        output: sink,
      );
      expect(
        prompt.readSecret('Password: ', valueName: 'password'),
        '  secret  ',
      );
      expect(events, [
        'terminal',
        'write Password: ',
        'get echo',
        'get line',
        'line true',
        'echo false',
        'read',
        'echo true',
        'line false',
        'newline',
      ]);
      expect(input.echo, isTrue);
      expect(input.line, isFalse);
      expect(sink.buffer.toString(), 'Password: \n');
    },
  );

  for (final value in <String?>[null, '']) {
    test('secret maps closed or empty input $value to null', () {
      final events = <String>[];
      final input = PromptTestInput(
        events: events,
        value: value,
        echo: false,
        line: true,
      );
      final prompt = NativeCommandPrompt(
        input: input,
        output: PromptTestSink(events: events),
      );
      expect(prompt.readSecret('Secret: ', valueName: 'secret'), isNull);
      expect(input.echo, isFalse);
      expect(input.line, isTrue);
      expect(events.last, 'newline');
    });
  }

  for (final failure in ['get echo', 'get line']) {
    test('snapshot failure $failure refuses reads and mode mutations', () {
      final events = <String>[];
      final input = PromptTestInput(events: events, failures: {failure});
      final prompt = NativeCommandPrompt(
        input: input,
        output: PromptTestSink(events: events),
      );
      expect(
        () => prompt.readSecret('Secret: ', valueName: 'secret'),
        throwsA(
          promptError(
            'Secure secret input is unavailable: Bad state: $failure',
          ),
        ),
      );
      expect(input.reads, 0);
      expect(input.echo, isTrue);
      expect(input.line, isFalse);
      expect(events, isNot(contains('newline')));
    });
  }

  for (final failure in ['line true', 'echo false']) {
    test('disable failure $failure refuses reads and restores both modes', () {
      final events = <String>[];
      final input = PromptTestInput(events: events, failures: {failure});
      final prompt = NativeCommandPrompt(
        input: input,
        output: PromptTestSink(events: events),
      );
      expect(
        () => prompt.readSecret('Secret: ', valueName: 'secret'),
        throwsA(
          promptError(
            'Could not disable terminal echo; refusing to read the secret: Bad state: $failure',
          ),
        ),
      );
      expect(input.reads, 0);
      expect(events.sublist(events.length - 3), [
        'echo true',
        'line false',
        'newline',
      ]);
      expect(input.echo, isTrue);
      expect(input.line, isFalse);
    });
  }

  test('read failure propagates after both modes are restored and newline', () {
    final events = <String>[];
    final input = PromptTestInput(events: events, failures: {'read'});
    final prompt = NativeCommandPrompt(
      input: input,
      output: PromptTestSink(events: events),
    );
    expect(
      () => prompt.readSecret('Secret: ', valueName: 'secret'),
      throwsStateError,
    );
    expect(events.sublist(events.length - 3), [
      'echo true',
      'line false',
      'newline',
    ]);
    expect(input.echo, isTrue);
    expect(input.line, isFalse);
  });

  for (final failure in ['echo true', 'line false']) {
    test(
      'restoration failure $failure does not prevent other restore or newline',
      () {
        final events = <String>[];
        final input = PromptTestInput(events: events, failures: {failure});
        final prompt = NativeCommandPrompt(
          input: input,
          output: PromptTestSink(events: events),
        );
        expect(prompt.readSecret('Secret: ', valueName: 'secret'), 'secret');
        expect(events.sublist(events.length - 3), [
          'echo true',
          'line false',
          'newline',
        ]);
        if (failure == 'echo true') {
          expect(input.line, isFalse);
        } else {
          expect(input.echo, isTrue);
        }
      },
    );
  }

  test('prompt output failure happens before console mode access', () {
    final events = <String>[];
    final input = PromptTestInput(events: events);
    final prompt = NativeCommandPrompt(
      input: input,
      output: PromptTestSink(events: events, failures: {'write Secret: '}),
    );
    expect(
      () => prompt.readSecret('Secret: ', valueName: 'secret'),
      throwsStateError,
    );
    expect(events, ['terminal', 'write Secret: ']);
    expect(input.reads, 0);
  });

  test('newline failure happens only after both modes are restored', () {
    final events = <String>[];
    final input = PromptTestInput(events: events);
    final prompt = NativeCommandPrompt(
      input: input,
      output: PromptTestSink(events: events, failures: {'newline'}),
    );
    expect(
      () => prompt.readSecret('Secret: ', valueName: 'secret'),
      throwsStateError,
    );
    expect(input.echo, isTrue);
    expect(input.line, isFalse);
    expect(events.sublist(events.length - 3), [
      'echo true',
      'line false',
      'newline',
    ]);
  });

  test(
    'line reads and writes use only the selected session without changing modes',
    () {
      final firstEvents = <String>[];
      final secondEvents = <String>[];
      final firstInput = PromptTestInput(
        events: firstEvents,
        value: 'first',
        terminal: false,
      );
      final secondInput = PromptTestInput(
        events: secondEvents,
        value: 'second',
      );
      final firstSink = PromptTestSink(events: firstEvents);
      final secondSink = PromptTestSink(events: secondEvents);
      final first = NativeCommandPrompt(input: firstInput, output: firstSink);
      final second = NativeCommandPrompt(
        input: secondInput,
        output: secondSink,
      );
      expect(first.isInteractive, isFalse);
      expect(second.isInteractive, isTrue);
      first.write('one ');
      second.write('two ');
      expect(first.readLine('choice: '), 'first');
      expect(second.readSecret('secret: ', valueName: 'secret'), 'second');
      firstInput.value = null;
      expect(first.readLine('closed: '), isNull);
      expect(firstEvents, [
        'terminal',
        'write one ',
        'write choice: ',
        'read',
        'write closed: ',
        'read',
      ]);
      expect(firstSink.buffer.toString(), 'one choice: closed: ');
      expect(secondSink.buffer.toString(), 'two secret: \n');
      expect(firstInput.reads, 2);
      expect(secondInput.reads, 1);
    },
  );
}
