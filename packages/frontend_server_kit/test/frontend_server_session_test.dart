import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:frontend_server_kit/frontend_server_kit.dart';
import 'package:test/test.dart';

/// Guards the stdin/stdout framing the session speaks with frontend_server.
/// A missing boundary terminator or wrong list order desynchronises the
/// compiler; a misparsed result line drops the dill path.
void main() {
  test('parseResultBoundary skips bare echo and returns dill path', () async {
    final queue = StreamQueue(
      Stream.fromIterable([
        'result abc123',
        'some warning',
        'abc123',
        'abc123 /tmp/out.dill 0',
      ]),
    );
    expect(
      await FrontendServerSession.parseResultBoundary(queue),
      '/tmp/out.dill',
    );
  });

  test('parseResultBoundary joins path tokens before error count', () async {
    final queue = StreamQueue(
      Stream.fromIterable(['result tok', r'tok C:\Users\me\My App\out.dill 0']),
    );
    expect(
      await FrontendServerSession.parseResultBoundary(queue),
      r'C:\Users\me\My App\out.dill',
    );
  });

  test(
    'nonzero error counts throw with diagnostics and preserve next result',
    () async {
      final queue = StreamQueue(
        Stream.fromIterable([
          'result bad',
          'Syntax error',
          'bad',
          'bad /tmp/bad.dill 2',
          'result good',
          'good',
          'good /tmp/good.dill 0',
        ]),
      );
      await expectLater(
        FrontendServerSession.parseResultBoundary(queue),
        throwsA(
          isA<FrontendServerException>()
              .having((error) => error.errorCount, 'errorCount', 2)
              .having(
                (error) => error.message,
                'message',
                contains('Syntax error'),
              ),
        ),
      );
      expect(
        await FrontendServerSession.parseResultBoundary(queue),
        '/tmp/good.dill',
      );
      await queue.cancel();
    },
  );

  test('boundary prefixes in diagnostics are not terminal results', () async {
    final queue = StreamQueue(
      Stream.fromIterable([
        'result tok',
        'token diagnostic',
        'tok',
        '+file:///source.dart',
        'tok /tmp/out.dill 0',
      ]),
    );
    expect(
      await FrontendServerSession.parseResultBoundary(queue),
      '/tmp/out.dill',
    );
    await queue.cancel();
  });

  for (final terminal in [
    'tok /tmp/out.dill nope',
    'tok /tmp/out.dill -1',
    'tok 0',
  ]) {
    test('malformed result $terminal throws', () async {
      final queue = StreamQueue(Stream.fromIterable(['result tok', terminal]));
      await expectLater(
        FrontendServerSession.parseResultBoundary(queue),
        throwsA(isA<FrontendServerException>()),
      );
      await queue.cancel();
    });
  }

  test(
    'reject acknowledgement completes on a live stream without consuming next result',
    () async {
      final controller = StreamController<String>();
      final queue = StreamQueue(controller.stream);
      addTearDown(() async {
        await queue.cancel(immediate: true);
        await controller.close();
      });
      final rejected = FrontendServerSession.parseRejectBoundary(queue);
      controller.add('result rejectKey');
      controller.add('rejectKey');
      await rejected.timeout(const Duration(seconds: 1));
      controller.add('result compileKey');
      controller.add('compileKey');
      controller.add('compileKey /tmp/next.dill 0');
      expect(
        await FrontendServerSession.parseResultBoundary(queue),
        '/tmp/next.dill',
      );
    },
  );

  test(
    'expression bare failure completes on a live stream and preserves framing',
    () async {
      final controller = StreamController<String>();
      final queue = StreamQueue(controller.stream);
      addTearDown(() async {
        await queue.cancel(immediate: true);
        await controller.close();
      });
      final failure = expectLater(
        FrontendServerSession.parseResultBoundary(
          queue,
          expectSources: false,
        ).timeout(const Duration(seconds: 1)),
        throwsA(
          isA<FrontendServerException>().having(
            (error) => error.message,
            'message',
            contains('Unknown name'),
          ),
        ),
      );
      controller.add('result expr');
      controller.add('Unknown name');
      controller.add('expr');
      await failure;
      controller.add('result next');
      controller.add('next /tmp/expression.dill 0');
      expect(
        await FrontendServerSession.parseResultBoundary(
          queue,
          expectSources: false,
        ),
        '/tmp/expression.dill',
      );
    },
  );

  test('closed incomplete response throws', () async {
    final queue = StreamQueue(Stream.fromIterable(['result tok', 'tok']));
    await expectLater(
      FrontendServerSession.parseResultBoundary(queue),
      throwsA(isA<FrontendServerException>()),
    );
    await queue.cancel();
  });

  final dartBin = File(Platform.resolvedExecutable).parent;
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      dartBin.parent.parent.parent.parent.path;
  final frontendServer = File(
    '${dartBin.path}/snapshots/frontend_server_aot.dart.snapshot',
  );
  final sdkRoot =
      '$flutterRoot/bin/cache/artifacts/engine/common/flutter_patched_sdk';
  final liveAvailable =
      frontendServer.existsSync() && Directory(sdkRoot).existsSync();

  for (final initiallyBroken in [false, true]) {
    test(
      'live frontend recovers from ${initiallyBroken ? 'compile' : 'recompile'} errors and expression failure',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'frontend_session_test',
        );
        final entrypoint = File('${temp.path}/main.dart');
        final source = File('${temp.path}/registrant.dart');
        final packages = File('${temp.path}/package_config.json');
        await packages.writeAsString('{"configVersion":2,"packages":[]}');
        await source.writeAsString('void registerPlugins() {}');
        await entrypoint.writeAsString(
          initiallyBroken ? 'void main( {' : 'void main() { print(1); }',
        );
        final arguments = <String>[];
        final session = FrontendServerSession(
          FrontendServerOptions(
            dart: '${dartBin.path}/dartaotruntime',
            frontendServer: frontendServer.path,
            sdkRoot: sdkRoot,
            packageConfig: packages.path,
            entrypoint: entrypoint.path,
            outputDill: '${temp.path}/out.dill',
            additionalSources: [source.uri],
            onTrace: arguments.add,
          ),
        );
        addTearDown(() async {
          await session.close();
          await temp.delete(recursive: true);
        });
        await session.spawn();
        expect(arguments.single, contains('--source ${source.uri}'));
        expect(arguments.single, contains('--no-link-platform'));
        if (initiallyBroken) {
          await expectLater(
            session.compile(),
            throwsA(
              isA<FrontendServerException>().having(
                (error) => error.errorCount,
                'errorCount',
                greaterThan(0),
              ),
            ),
          );
          await entrypoint.writeAsString('void main() { print(1); }');
          expect(
            File(
              await session.recompile(invalidated: [entrypoint.uri.toString()]),
            ).existsSync(),
            isTrue,
          );
        } else {
          expect(File(await session.compile()).existsSync(), isTrue);
        }
        await session.accept();
        await entrypoint.writeAsString('void main( {');
        await expectLater(
          session.recompile(invalidated: [entrypoint.uri.toString()]),
          throwsA(
            isA<FrontendServerException>().having(
              (error) => error.errorCount,
              'errorCount',
              greaterThan(0),
            ),
          ),
        );
        await entrypoint.writeAsString('void main() { print(2); }');
        expect(
          File(
            await session.recompile(invalidated: [entrypoint.uri.toString()]),
          ).existsSync(),
          isTrue,
        );
        await session.reject().timeout(const Duration(seconds: 5));
        expect(
          File(
            await session.recompile(invalidated: [entrypoint.uri.toString()]),
          ).existsSync(),
          isTrue,
        );
        await session.accept();
        Future<List<int>> expression(String value) => session.compileExpression(
          expression: value,
          definitions: [],
          definitionTypes: [],
          typeDefinitions: [],
          typeBounds: [],
          typeDefaults: [],
          libraryUri: entrypoint.uri.toString(),
          klass: null,
          method: 'main',
          isStatic: true,
        );
        await expectLater(
          expression('missingIdentifier +').timeout(const Duration(seconds: 5)),
          throwsA(isA<FrontendServerException>()),
        );
        expect(await expression('1 + 2'), isNotEmpty);
        expect(
          File(await session.recompile(invalidated: [])).existsSync(),
          isTrue,
        );
        await session.accept();
      },
      skip: liveAvailable ? false : 'Flutter frontend_server SDK unavailable',
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  test(
    'buildCompileExpressionCommand keeps fixed list order and terminators',
    () {
      final payload = FrontendServerSession.buildCompileExpressionCommand(
        boundaryKey: 'k1',
        expression: 'a + b',
        definitions: ['a', 'b'],
        definitionTypes: ['int', 'int'],
        typeDefinitions: ['T'],
        typeBounds: ['Object'],
        typeDefaults: ['dynamic'],
        libraryUri: 'package:app/main.dart',
        klass: 'Foo',
        method: 'bar',
        isStatic: false,
      );
      expect(
        payload,
        'compile-expression k1\n'
        'a + b\n'
        'a\n'
        'b\n'
        'k1\n'
        'int\n'
        'int\n'
        'k1\n'
        'T\n'
        'k1\n'
        'Object\n'
        'k1\n'
        'dynamic\n'
        'k1\n'
        'package:app/main.dart\n'
        'Foo\n'
        'bar\n'
        'false\n',
      );
    },
  );

  test('buildCompileExpressionCommand uses empty klass/method when null', () {
    final payload = FrontendServerSession.buildCompileExpressionCommand(
      boundaryKey: 'k2',
      expression: '1',
      definitions: const [],
      definitionTypes: const [],
      typeDefinitions: const [],
      typeBounds: const [],
      typeDefaults: const [],
      libraryUri: 'dart:core',
      klass: null,
      method: null,
      isStatic: true,
    );
    expect(
      payload,
      'compile-expression k2\n'
      '1\n'
      'k2\n'
      'k2\n'
      'k2\n'
      'k2\n'
      'k2\n'
      'dart:core\n'
      '\n'
      '\n'
      'true\n',
    );
  });
}
