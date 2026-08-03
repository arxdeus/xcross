import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross_flutter/src/models/flutter/flutter_build_options.dart';

void main() {
  group('FlutterBuildOptions.resolve', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xcross_build_options-');
    });

    tearDown(() => tmp.delete(recursive: true));

    Future<String> writeJsonDefine(String content) async {
      final path = p.join(tmp.path, 'defines.json');
      await File(path).writeAsString(content);
      return path;
    }

    test('wires dart-define-from-file (first) and --dart-define (last), and '
        'passes through the other fields', () async {
      final fromFilePath = await writeJsonDefine('{"FROM_FILE": 1}');

      final options = await FlutterBuildOptions.resolve(
        target: 'lib/other.dart',
        dartDefine: ['EXPLICIT=2'],
        dartDefineFromFile: [fromFilePath],
        pub: false,
        buildName: '2.0.0',
        buildNumber: '42',
        flavor: 'dev',
      );

      expect(options.target, 'lib/other.dart');
      expect(options.dartDefines, ['FROM_FILE=1', 'EXPLICIT=2']);
      expect(options.pub, isFalse);
      expect(options.buildName, '2.0.0');
      expect(options.buildNumber, '42');
      expect(options.flavor, 'dev');
    });

    test('defaults buildName/buildNumber/flavor to null and dartDefines to '
        'empty when omitted', () async {
      final options = await FlutterBuildOptions.resolve(
        target: 'lib/main.dart',
        dartDefine: [],
        dartDefineFromFile: [],
        pub: true,
      );

      expect(options.target, 'lib/main.dart');
      expect(options.pub, isTrue);
      expect(options.buildName, isNull);
      expect(options.buildNumber, isNull);
      expect(options.flavor, isNull);
      expect(options.dartDefines, isEmpty);
    });

    test(
      'carries an explicit-only dartDefine list through untouched',
      () async {
        final options = await FlutterBuildOptions.resolve(
          target: 'lib/main.dart',
          dartDefine: ['A=1'],
          dartDefineFromFile: [],
          pub: true,
        );

        expect(options.dartDefines, ['A=1']);
      },
    );

    test('carries a dartDefineFromFile-only list through merged', () async {
      final fromFilePath = await writeJsonDefine('{"A": 1, "B": 2}');

      final options = await FlutterBuildOptions.resolve(
        target: 'lib/main.dart',
        dartDefine: [],
        dartDefineFromFile: [fromFilePath],
        pub: true,
      );

      expect(options.dartDefines, ['A=1', 'B=2']);
    });
  });
}
