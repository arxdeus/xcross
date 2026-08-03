import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross_flutter/src/errors.dart';
import 'package:xcross_flutter/src/models/flutter/dart_defines.dart';

void main() {
  group('DartDefines.mergeDartDefines', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xcross_dart_defines-');
    });

    tearDown(() => tmp.delete(recursive: true));

    Future<String> writeFile(String name, String content) async {
      final path = p.join(tmp.path, name);
      await File(path).writeAsString(content);
      return path;
    }

    test('mergeDartDefines([], []) returns an empty list', () async {
      expect(await DartDefines.mergeDartDefines([], []), isEmpty);
    });

    test(
      'reads a .json object into KEY=VALUE strings, preserving key order',
      () async {
        final path = await writeFile('defines.json', '{"A": 1, "B": 2}');

        expect(await DartDefines.mergeDartDefines([path], []), ['A=1', 'B=2']);
      },
    );

    // jsonDecode gives a Dart bool; the merge uses Dart's toString (not
    // jsonEncode), so a JSON boolean must come out as the bare word `true`.
    test('renders JSON boolean values via Dart toString, not JSON', () async {
      final path = await writeFile('defines.json', '{"FLAG": true}');

      expect(await DartDefines.mergeDartDefines([path], []), ['FLAG=true']);
    });

    test(
      'parses env-style files, skipping comments/blanks/no-equals lines',
      () async {
        final path = await writeFile(
          'defines.env',
          'K1=V1\n# comment\n\nK2=V2=extra=stuff\nNOEQUALS\n',
        );

        expect(await DartDefines.mergeDartDefines([path], []), [
          'K1=V1',
          'K2=V2=extra=stuff',
        ]);
      },
    );

    test('trims surrounding whitespace but keeps the line verbatim', () async {
      final path = await writeFile('defines.env', '   K3=V3   \n');

      expect(await DartDefines.mergeDartDefines([path], []), ['K3=V3']);
    });

    // Extension check only special-cases `.json`; anything else (even a
    // non-`.env` extension) falls through to env-style line parsing as long
    // as the content doesn't start with `{`.
    test(
      'treats a non-.json, non-{ file as env-style regardless of extension',
      () async {
        final path = await writeFile('defines.txt', 'X=1\n');

        expect(await DartDefines.mergeDartDefines([path], []), ['X=1']);
      },
    );

    test(
      'emits all file entries (in order) before explicit entries, without deduping',
      () async {
        final file1 = await writeFile('file1.env', 'K=fromFile1\n');
        final file2 = await writeFile('file2.env', 'K=fromFile2\n');

        expect(
          await DartDefines.mergeDartDefines([file1, file2], ['K=explicit']),
          ['K=fromFile1', 'K=fromFile2', 'K=explicit'],
        );
      },
    );

    test(
      'preserves explicit-only entries unsorted and undeduplicated',
      () async {
        expect(await DartDefines.mergeDartDefines([], ['B=2', 'A=1', 'A=1']), [
          'B=2',
          'A=1',
          'A=1',
        ]);
      },
    );

    test('throws FlutterBuildError when a file is missing', () async {
      final path = p.join(tmp.path, 'does_not_exist.json');

      await expectLater(
        DartDefines.mergeDartDefines([path], []),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.message,
            'message',
            contains('file not found'),
          ),
        ),
      );
    });

    test(
      'throws FlutterBuildError when a .json file is not a JSON object',
      () async {
        final path = await writeFile('defines.json', '[1, 2, 3]');

        await expectLater(
          DartDefines.mergeDartDefines([path], []),
          throwsA(
            isA<FlutterBuildError>().having(
              (e) => e.message,
              'message',
              contains('is not a JSON object'),
            ),
          ),
        );
      },
    );
  });
}
