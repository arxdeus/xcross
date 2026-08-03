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
      Stream.fromIterable(['result tok', r'tok C:\Users\me\My App\out.dill 2']),
    );
    expect(
      await FrontendServerSession.parseResultBoundary(queue),
      r'C:\Users\me\My App\out.dill',
    );
  });

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
