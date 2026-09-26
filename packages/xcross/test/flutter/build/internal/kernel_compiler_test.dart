import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/kernel_compiler.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
  group('argsForKey', () {
    test(
      'drops --output-dill and --initialize-from-dill with their values',
      () {
        final result = KernelWarmStart.argsForKey([
          '--sdk-root',
          '/sdk/',
          '--output-dill',
          '/build/app.dill',
          '--incremental',
          '--initialize-from-dill',
          '/build/app.dill',
          '--packages',
          '/proj/.dart_tool/package_config.json',
        ]);

        expect(result, [
          '--sdk-root',
          '/sdk/',
          '--incremental',
          '--packages',
          '/proj/.dart_tool/package_config.json',
        ]);
      },
    );
  });

  group('computeKey', () {
    String key({
      List<String> args = const ['--target=flutter'],
      String runtime = '/rt/dart',
      String snapshot = '/rt/frontend_server.dart.snapshot',
      String engineHash = 'abc123',
      String packageConfigContent = '{"configVersion":2}',
    }) => KernelWarmStart.computeKey(
      args: args,
      runtime: runtime,
      snapshot: snapshot,
      engineHash: engineHash,
      packageConfigContent: packageConfigContent,
    );

    test('is stable for identical inputs', () {
      expect(key(), key());
    });

    test('changes when a -D define changes', () {
      expect(key(args: ['-Dfoo=1']), isNot(key(args: ['-Dfoo=2'])));
    });

    test('changes when the flavor define changes', () {
      expect(
        key(args: ['-DFLUTTER_APP_FLAVOR=dev']),
        isNot(key(args: ['-DFLUTTER_APP_FLAVOR=prod'])),
      );
    });

    test('changes when the entrypoint changes', () {
      expect(
        key(args: ['package:app/main.dart']),
        isNot(key(args: ['package:app/other.dart'])),
      );
    });

    test('changes when package_config.json content changes', () {
      expect(
        key(packageConfigContent: '{"a":1}'),
        isNot(key(packageConfigContent: '{"a":2}')),
      );
    });

    test('changes when the engine hash changes', () {
      expect(key(engineHash: 'one'), isNot(key(engineHash: 'two')));
    });

    test('is unaffected by the output/initialize-from-dill path values', () {
      expect(
        key(
          args: [
            '--output-dill',
            '/a/app.dill',
            '--target=flutter',
            '--incremental',
            '--initialize-from-dill',
            '/a/app.dill',
          ],
        ),
        key(
          args: [
            '--output-dill',
            '/b/app.dill',
            '--target=flutter',
            '--incremental',
            '--initialize-from-dill',
            '/b/app.dill',
          ],
        ),
      );
    });
  });

  group('compileWithWarmStart', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xcross_warm_start-');
    });

    tearDown(() => tmp.delete(recursive: true));

    String outputDill() => '${tmp.path}/app.dill';
    String keyPath() => KernelWarmStart.keyPathFor(outputDill());

    test('writes the key only after a successful compile', () async {
      await KernelWarmStart.compileWithWarmStart(
        outputDill: outputDill(),
        warmStartKey: 'key-1',
        compile: () async {
          File(outputDill()).writeAsStringSync('dill-bytes');
        },
      );

      expect(File(outputDill()).existsSync(), isTrue);
      expect(File(keyPath()).readAsStringSync(), 'key-1');
    });

    test('deletes a stale dill and key when the key does not match', () async {
      File(outputDill()).writeAsStringSync('stale-dill');
      File(keyPath()).writeAsStringSync('old-key');

      String? sawExistingDill;
      await KernelWarmStart.compileWithWarmStart(
        outputDill: outputDill(),
        warmStartKey: 'new-key',
        compile: () async {
          sawExistingDill = File(outputDill()).existsSync()
              ? File(outputDill()).readAsStringSync()
              : null;
          File(outputDill()).writeAsStringSync('fresh-dill');
        },
      );

      // The stale dill must be gone before compile runs, so frontend_server
      // never silently warm-starts from build inputs that no longer match.
      expect(sawExistingDill, isNull);
      expect(File(outputDill()).readAsStringSync(), 'fresh-dill');
      expect(File(keyPath()).readAsStringSync(), 'new-key');
    });

    test('keeps the dill in place when the key matches (warm start)', () async {
      File(outputDill()).writeAsStringSync('warm-dill');
      File(keyPath()).writeAsStringSync('same-key');

      String? sawExistingDill;
      await KernelWarmStart.compileWithWarmStart(
        outputDill: outputDill(),
        warmStartKey: 'same-key',
        compile: () async {
          sawExistingDill = File(outputDill()).existsSync()
              ? File(outputDill()).readAsStringSync()
              : null;
        },
      );

      expect(sawExistingDill, 'warm-dill');
    });

    test('deletes dill and key when compile throws', () async {
      File(outputDill()).writeAsStringSync('existing-dill');
      File(keyPath()).writeAsStringSync('existing-key');

      await expectLater(
        KernelWarmStart.compileWithWarmStart(
          outputDill: outputDill(),
          warmStartKey: 'existing-key',
          compile: () => Future.sync(() {
            File(outputDill()).writeAsStringSync('half-written');
            throw StateError('frontend_server crashed');
          }),
        ),
        throwsA(isA<StateError>()),
      );

      expect(File(outputDill()).existsSync(), isFalse);
      expect(File(keyPath()).existsSync(), isFalse);
    });

    test(
      'deletes dill and key when compile succeeds but leaves no dill',
      () async {
        await expectLater(
          KernelWarmStart.compileWithWarmStart(
            outputDill: outputDill(),
            warmStartKey: 'key',
            compile: Future.value,
          ),
          throwsA(isA<FlutterBuildError>()),
        );

        expect(File(outputDill()).existsSync(), isFalse);
        expect(File(keyPath()).existsSync(), isFalse);
      },
    );
  });
}
