import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:frontend_server_kit/frontend_server_kit.dart';
import 'package:test/test.dart';

import 'test_log_output.dart';

void main() {
  late Directory directory;
  late Factory factory;
  late FrontendServerSession session;
  late List<String> diagnostics;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('compiler_lifecycle_');
    factory = Factory();
    diagnostics = [];
    session = FrontendServerSession(
      FrontendServerOptions(
        dart: 'owned-dart',
        frontendServer: 'frontend_server_aot.dart.snapshot',
        sdkRoot: '/sdk',
        packageConfig: '${directory.path}/missing.json',
        entrypoint: '${directory.path}/main.dart',
        outputDill: '${directory.path}/out.dill',
      ),
      processFactory: factory,
      diagnostics: diagnostics.add,
    );
  });

  tearDown(() async {
    await session.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'injected transport receives commands and isolated diagnostics',
    () async {
      await session.spawn();
      expect(factory.executable, 'owned-dart');
      expect(factory.arguments, isNot(contains('--disable-dart-dev')));
      factory.transports.single.errors.add('diagnostic');
      final result = await session.compile();
      expect(result, '/compiled.dill');
      expect(diagnostics, ['diagnostic']);
      expect(
        factory.transports.single.commands.single,
        startsWith('compile file:'),
      );
    },
  );

  test(
    'incremental commands serialize and close permits a fresh session',
    () async {
      await session.spawn();
      await Future.wait([
        session.compile(),
        session.reset(),
        session.accept(),
        session.recompile(invalidated: const []),
      ]);
      expect(
        factory.transports.single.commands.map(
          (s) => s.split(' ').first.trim(),
        ),
        ['compile', 'reset', 'accept', 'recompile'],
      );
      await session.close();
      await session.close();
      expect(factory.transports.single.closes, 1);
      await session.spawn();
      expect(factory.transports, hasLength(2));
      expect(await session.compile(), '/compiled.dill');
    },
  );

  test(
    'native adapter launches an owned child with its immutable environment',
    () async {
      final child = File('${directory.path}/child.dart');
      child.writeAsStringSync(r"""
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  stderr.writeln('environment=${Platform.environment['COMPILER_TEST']}');
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.startsWith('compile ')) {
      stdout.writeln('result native');
      stdout.writeln('native /native.dill 0');
    }
    if (line == 'quit') return;
  }
}
""");
      final runner = ProcessRunner(
        MacOSHost(environment: Platform.environment),
        configuration: ProcessConfiguration(
          normalizedTools: const {},
          effectiveChildEnvironment: {
            ...Platform.environment,
            'COMPILER_TEST': 'session-scope',
          },
        ),
        log: testLog(),
      );
      final environmentSeen = Completer<String>();
      session = FrontendServerSession(
        FrontendServerOptions(
          dart: Platform.resolvedExecutable,
          frontendServer: child.path,
          sdkRoot: '/sdk',
          packageConfig: '${directory.path}/missing.json',
          entrypoint: '${directory.path}/main.dart',
          outputDill: '${directory.path}/native.dill',
        ),
        processFactory: HostCompilerProcessFactory(runner),
        diagnostics: (line) {
          if (line.startsWith('environment=')) environmentSeen.complete(line);
        },
      );
      await session.spawn();
      expect(await session.compile(), '/native.dill');
      expect(
        await environmentSeen.future.timeout(const Duration(seconds: 5)),
        'environment=session-scope',
      );
      await session.close();
    },
  );

  test(
    'close during startup reaps the compiler and rejects concurrent spawn',
    () async {
      factory.startupGate = Completer<void>();
      factory.entered = Completer<void>();
      final starting = session.spawn();
      await factory.entered!.future;
      await expectLater(
        session.spawn(),
        throwsA(isA<FrontendServerException>()),
      );
      final closing = session.close();
      factory.startupGate!.complete();
      await Future.wait([starting, closing]);
      expect(factory.transports, hasLength(1));
      expect(factory.transports.single.closes, 1);
      await session.spawn();
      expect(factory.transports, hasLength(2));
    },
  );

  test('duplicate spawn does not launch an untracked compiler', () async {
    await session.spawn();
    await expectLater(session.spawn(), throwsA(isA<FrontendServerException>()));
    expect(factory.transports, hasLength(1));
  });
}

final class Factory implements CompilerProcessFactory {
  final List<Transport> transports = [];
  Completer<void>? startupGate;
  Completer<void>? entered;
  String? executable;
  List<String>? arguments;

  @override
  Future<CompilerTransport> start(
    String executable,
    List<String> arguments,
  ) async {
    this.executable = executable;
    this.arguments = List.of(arguments);
    final transport = Transport();
    transports.add(transport);
    if (entered case final signal? when !signal.isCompleted) signal.complete();
    await startupGate?.future;
    return transport;
  }
}

final class Transport implements CompilerTransport {
  final lines = StreamController<String>();
  final errors = StreamController<String>();
  final commands = <String>[];
  int closes = 0;

  @override
  Stream<String> get output => lines.stream;
  @override
  Stream<String> get diagnostics => errors.stream;
  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> send(String command) async {
    commands.add(command);
    if (command.startsWith('compile ') || command.startsWith('recompile ')) {
      lines.add('result boundary');
      lines.add('boundary /compiled.dill 0');
    }
  }

  @override
  Future<void> close() async {
    closes++;
    await lines.close();
    await errors.close();
  }
}
