import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dds/dap.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/dap/dap_router.dart';
import 'package:xcross/src/dap/internal/dap_router.dart';

import '../device/test_log_output.dart';

void main() {
  final runner = ProcessRunner(
    stdinStream: const Stream.empty(),
    stdoutSink: testSink(),
    stderrSink: testSink(),
    MacOSHost(),
    log: testLog(),
  );

  test('configured Flutter environment wins with legacy fallbacks enabled', () {
    final router = DapRouter(
      const Stream<List<int>>.empty(),
      StreamController<List<int>>().sink,
      (_) {},
      runner: runner,
      errors: testSink(),
      environmentRoot: '/configured/environment/flutter',
    );

    expect(
      router.resolveFlutterExecutable(),
      p.join('/configured/environment/flutter', 'bin', 'flutter'),
    );
  });

  test(
    'host paths and immutable resolution stay isolated between sessions',
    () {
      final output = StreamController<List<int>>.broadcast();
      addTearDown(output.close);
      final windows = ProcessRunner(
        stdinStream: const Stream.empty(),
        stdoutSink: testSink(),
        stderrSink: testSink(),
        WindowsHost(),
        log: testLog(),
      );
      final first = DapRouter(
        const Stream<List<int>>.empty(),
        output.sink,
        (_) {},
        runner: windows,
        errors: testSink(),
        flutterRoot: r'C:\flutter',
      );
      final second = DapRouter(
        const Stream<List<int>>.empty(),
        output.sink,
        (_) {},
        runner: runner,
        errors: testSink(),
        flutterRoot: '/other/flutter',
      );
      expect(first.resolveFlutterExecutable(), r'C:\flutter\bin\flutter.bat');
      expect(second.resolveFlutterExecutable(), '/other/flutter/bin/flutter');
      expect(first.resolveFlutterExecutable(), r'C:\flutter\bin\flutter.bat');
    },
  );

  for (final windows in [false, true]) {
    test(
      'test adapter forces configured ${windows ? "Windows" : "POSIX"} Flutter proxy',
      () async {
        final processes = TestAdapterProcesses();
        final host = windows
            ? WindowsHost(processes: processes)
            : MacOSHost(processes: processes);
        final runner = ProcessRunner(
          stdinStream: const Stream.empty(),
          stdoutSink: testSink(),
          stderrSink: testSink(),
          host,
          log: testLog(),
        );
        final input = StreamController<List<int>>();
        final output = StreamController<List<int>>();
        output.stream.listen((_) {});
        final root = windows ? r'C:\selected\flutter' : '/selected/flutter';
        var xcrossStarted = false;
        final running = DapSession.run(
          input: input.stream,
          output: output.sink,
          startXcross: (_) => xcrossStarted = true,
          runner: runner,
          errors: testSink(),
          flutterRoot: root,
          testAdapter: true,
          flutterAdapterArguments: const ['--verbose'],
        );
        input.add(
          DapFrame.encode({
            'seq': 1,
            'type': 'request',
            'command': 'launch',
            'arguments': {
              'env': {'XCROSS': 'true'},
            },
          }),
        );
        await processes.started.future;
        expect(xcrossStarted, isFalse);
        expect(
          processes.executable,
          windows
              ? r'C:\selected\flutter\bin\flutter.bat'
              : '/selected/flutter/bin/flutter',
        );
        expect(processes.arguments, ['debug-adapter', '--test', '--verbose']);
        await input.close();
        await running;
        await processes.child.stdin.done;
        expect(
          DapFrameParser().push(processes.child.input).single.json['command'],
          'launch',
        );
      },
    );
  }

  test('Flutter adapter arguments are an immutable session snapshot', () {
    final arguments = ['--verbose'];
    final output = StreamController<List<int>>();
    output.stream.listen((_) {});
    addTearDown(output.close);
    final router = DapRouter(
      const Stream.empty(),
      output.sink,
      (_) {},
      runner: runner,
      errors: testSink(),
      flutterAdapterArguments: arguments,
    );
    arguments.add('--test');
    expect(router.flutterAdapterArguments, ['--verbose']);
    expect(
      () => router.flutterAdapterArguments.add('mutate'),
      throwsUnsupportedError,
    );
  });

  test('DapFrameParser splits Content-Length frames across chunks', () {
    final parser = DapFrameParser();
    final msg = DapFrame.encode({
      'seq': 1,
      'type': 'request',
      'command': 'initialize',
      'arguments': {'adapterID': 'dart'},
    });

    final mid = msg.length ~/ 2;
    expect(parser.push(msg.sublist(0, mid)), isEmpty);

    final frames = parser.push(msg.sublist(mid));
    expect(frames, hasLength(1));
    expect(frames.single.json['command'], 'initialize');
    expect(frames.single.raw, msg);
  });

  test(
    'DapResponseFilter drops answered responses and one initialized event',
    () async {
      final out = StreamController<List<int>>();
      final received = <Map<String, Object?>>[];
      out.stream.listen((chunk) {
        final parser = DapFrameParser();
        for (final frame in parser.push(chunk)) {
          received.add(frame.json);
        }
      });

      final filter = DapResponseFilter(out, {1, 2});
      filter.add(
        DapFrame.encode({
          'seq': 10,
          'type': 'response',
          'request_seq': 1,
          'success': true,
          'command': 'initialize',
        }),
      );
      filter.add(
        DapFrame.encode({
          'seq': 11,
          'type': 'event',
          'event': 'initialized',
          'body': <String, Object?>{},
        }),
      );
      filter.add(
        DapFrame.encode({
          'seq': 12,
          'type': 'response',
          'request_seq': 3,
          'success': true,
          'command': 'launch',
        }),
      );
      filter.add(
        DapFrame.encode({
          'seq': 13,
          'type': 'event',
          'event': 'output',
          'body': {'output': 'hi'},
        }),
      );
      await filter.close();
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(2));
      expect(received[0]['command'], 'launch');
      expect(received[1]['event'], 'output');
    },
  );

  test('DapSession.run with XCROSS env starts the xcross adapter', () async {
    final inbound = StreamController<List<int>>();
    final outbound = StreamController<List<int>>();
    ByteStreamServerChannel? started;

    final session = DapSession.run(
      runner: runner,
      errors: testSink(),
      startXcross: (channel) {
        started = channel;
        // Don't run a real adapter — just close once launch is replayed.
        channel.listen((_) {}, onDone: channel.close);
      },
      input: inbound.stream,
      output: outbound,
    );

    void send(Map<String, Object?> msg) => inbound.add(DapFrame.encode(msg));

    send({
      'seq': 1,
      'type': 'request',
      'command': 'initialize',
      'arguments': {'adapterID': 'dart'},
    });
    send({'seq': 2, 'type': 'request', 'command': 'configurationDone'});
    send({
      'seq': 3,
      'type': 'request',
      'command': 'launch',
      'arguments': {
        'program': 'lib/main.dart',
        'env': {'XCROSS': 'true'},
      },
    });
    await inbound.close();
    await session;

    expect(started, isNotNull);
  });
}

final class TestAdapterProcesses implements HostProcessInterface {
  final child = TestAdapterChild();
  final started = Completer<void>();
  String? executable;
  List<String>? arguments;
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    this.executable = executable;
    this.arguments = List.of(arguments);
    started.complete();
    return child;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected process operation');
}

final class TestAdapterChild implements Process {
  TestAdapterChild() {
    sink = IOSink(inbound.sink);
    inbound.stream.listen(
      input.addAll,
      onDone: () {
        exit.complete(0);
        unawaited(output.close());
        unawaited(errors.close());
      },
    );
  }
  final input = <int>[];
  final inbound = StreamController<List<int>>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exit = Completer<int>();
  late final IOSink sink;
  @override
  IOSink get stdin => sink;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected child operation');
}
