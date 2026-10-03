import 'dart:async';
import 'dart:io';

import 'package:frontend_server_kit/frontend_server_kit.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late _Factory factory;
  late FrontendServerSession session;
  late List<String> diagnostics;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('compiler_lifecycle_');
    factory = _Factory();
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

  test('duplicate spawn does not launch an untracked compiler', () async {
    await session.spawn();
    await expectLater(session.spawn(), throwsA(isA<FrontendServerException>()));
    expect(factory.transports, hasLength(1));
  });
}

final class _Factory implements CompilerProcessFactory {
  final List<_Transport> transports = [];
  String? executable;
  List<String>? arguments;

  @override
  Future<CompilerTransport> start(
    String executable,
    List<String> arguments,
  ) async {
    this.executable = executable;
    this.arguments = List.of(arguments);
    final transport = _Transport();
    transports.add(transport);
    return transport;
  }
}

final class _Transport implements CompilerTransport {
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
