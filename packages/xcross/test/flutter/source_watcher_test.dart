import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/hot_reload/source_watcher.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_source_watcher-');
  });

  tearDown(() => tmp.delete(recursive: true));

  void writeFile(String relativePath, [String content = '// dummy\n']) {
    final file = File(p.join(tmp.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  group('dartFiles', () {
    test('scans lib/ recursively and prunes dot-directories and build/', () {
      writeFile(p.join('lib', 'a.dart'));
      writeFile(p.join('lib', 'sub', 'b.dart'));
      writeFile(p.join('lib', '.hidden', 'skip.dart'));
      writeFile(p.join('lib', 'build', 'skip2.dart'));
      writeFile('other.dart'); // outside lib/, must not be picked up

      final watcher = SourceWatcher(tmp.path);
      final basenames = watcher.dartFiles().map(p.basename).toSet();

      expect(basenames, {'a.dart', 'b.dart'});
    });

    test('tracks an explicit entrypoint outside lib and its deletion', () {
      writeFile('lib/a.dart');
      writeFile('main.dart');
      final path = p.join(tmp.path, 'main.dart');
      final watcher = SourceWatcher(tmp.path, additionalFiles: [path])
        ..snapshot();
      writeFile('main.dart', 'changed');
      expect(watcher.changedFileUris(), [Uri.file(path).toString()]);
      File(path).deleteSync();
      expect(watcher.changedFileUris(), [Uri.file(path).toString()]);
    });

    test('returns absolute paths', () {
      writeFile(p.join('lib', 'a.dart'));
      final watcher = SourceWatcher(tmp.path);
      final files = watcher.dartFiles();
      expect(files, hasLength(1));
      expect(p.isAbsolute(files.single), isTrue);
    });

    test('falls back to projectRoot itself when lib/ does not exist', () {
      writeFile('other.dart'); // no lib/ dir at all
      final watcher = SourceWatcher(tmp.path);
      final basenames = watcher.dartFiles().map(p.basename).toSet();
      expect(basenames, {'other.dart'});
    });

    test('returns an empty list when projectRoot does not exist', () {
      final missing = p.join(tmp.path, 'does_not_exist');
      final watcher = SourceWatcher(missing);
      expect(watcher.dartFiles(), isEmpty);
    });
  });

  group('package config', () {
    void configure(List<Object?> packages, {String? path}) {
      writeFile(
        path ?? '.dart_tool/package_config.json',
        jsonEncode({'configVersion': 2, 'packages': packages}),
      );
    }

    test('tracks relative and absolute local package source roots', () {
      writeFile('lib/main.dart');
      writeFile('dependency/lib/local.dart');
      writeFile('absolute/source/absolute.dart');
      writeFile('dependency/test/ignored.dart');
      configure([
        {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
        {'name': 'local', 'rootUri': '../dependency', 'packageUri': 'lib/'},
        {
          'name': 'absolute',
          'rootUri': Uri.directory(p.join(tmp.path, 'absolute')).toString(),
          'packageUri': 'source/',
        },
      ]);
      final watcher = SourceWatcher(tmp.path);
      expect(
        watcher.dartFiles().map(p.basename),
        unorderedEquals(['main.dart', 'local.dart', 'absolute.dart']),
      );
      watcher.snapshot();
      writeFile('dependency/lib/local.dart', 'changed');
      expect(watcher.changedFileUris(), [
        Uri.file(p.join(tmp.path, 'dependency/lib/local.dart')).toString(),
      ]);
    });

    test('uses the supplied workspace package config path', () {
      writeFile('app/lib/main.dart');
      writeFile('dependency/lib/local.dart');
      configure([
        {'name': 'local', 'rootUri': '../dependency', 'packageUri': 'lib/'},
      ]);
      final watcher = SourceWatcher(
        p.join(tmp.path, 'app'),
        packageConfig: p.join(tmp.path, '.dart_tool/package_config.json'),
      );
      expect(
        watcher.dartFiles().map(p.basename),
        unorderedEquals(['main.dart', 'local.dart']),
      );
    });

    test('does not scan Flutter SDK package sources', () {
      writeFile('lib/main.dart');
      writeFile('sdk/packages/flutter/lib/framework.dart');
      writeFile('sdk/packages/flutter_test/lib/test.dart');
      configure([
        {'name': 'flutter', 'rootUri': '../sdk/packages/flutter/'},
        {'name': 'flutter_test', 'rootUri': '../sdk/packages/flutter_test/'},
      ]);
      expect(SourceWatcher(tmp.path).dartFiles().map(p.basename), [
        'main.dart',
      ]);
    });

    test('honors package config pubCache and flutterRoot metadata', () {
      writeFile('lib/main.dart');
      writeFile('custom-cache/hosted/package/lib/dependency.dart');
      writeFile('custom-sdk/packages/other/lib/sdk.dart');
      writeFile(
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'pubCache': Uri.directory(
            p.join(tmp.path, 'custom-cache'),
          ).toString(),
          'flutterRoot': Uri.directory(
            p.join(tmp.path, 'custom-sdk'),
          ).toString(),
          'packages': [
            {'name': 'hosted', 'rootUri': '../custom-cache/hosted/package/'},
            {'name': 'sdk', 'rootUri': '../custom-sdk/packages/other/'},
          ],
        }),
      );
      expect(SourceWatcher(tmp.path).dartFiles().map(p.basename), [
        'main.dart',
      ]);
    });

    test('tolerates missing malformed and non-file config entries', () {
      writeFile('lib/main.dart');
      final watcher = SourceWatcher(tmp.path);
      writeFile('.dart_tool/package_config.json', '{');
      expect(watcher.dartFiles(), hasLength(1));
      configure([
        null,
        {},
        {'rootUri': 3},
        {'rootUri': 'https://example.com/'},
      ]);
      expect(watcher.dartFiles(), hasLength(1));
    });

    test('discovers package roots added after the snapshot', () {
      writeFile('lib/main.dart');
      configure([]);
      final watcher = SourceWatcher(tmp.path)..snapshot();
      writeFile('dependency/lib/local.dart');
      configure([
        {'name': 'local', 'rootUri': '../dependency'},
      ]);
      expect(watcher.changedFileUris(), [
        Uri.file(p.join(tmp.path, 'dependency/lib/local.dart')).toString(),
      ]);
    });
  });

  group('snapshot / changedFileUris', () {
    test('reports nothing changed right after a snapshot', () {
      writeFile(p.join('lib', 'a.dart'));
      final watcher = SourceWatcher(tmp.path);
      watcher.snapshot();
      expect(watcher.changedFileUris(), isEmpty);
    });

    // Regression check for the documented "not pure" contract: the first
    // call must report the edit, and — because it also advances the
    // baseline — an immediate second call with no further edits must not.
    test('reports an edited file once, then advances the baseline', () {
      writeFile(p.join('lib', 'a.dart'));
      final watcher = SourceWatcher(tmp.path);
      final aPath = watcher.dartFiles().single;
      watcher.snapshot();

      File(aPath).writeAsStringSync('// changed\n');

      expect(watcher.changedFileUris(), [Uri.file(aPath).toString()]);
      expect(watcher.changedFileUris(), isEmpty);
    });

    test('only reports the file that actually changed', () {
      writeFile(p.join('lib', 'a.dart'), '// a\n');
      writeFile(p.join('lib', 'b.dart'), '// b\n');
      final watcher = SourceWatcher(tmp.path);
      watcher.snapshot();

      final bPath = watcher.dartFiles().firstWhere(
        (f) => p.basename(f) == 'b.dart',
      );
      File(bPath).writeAsStringSync('// b changed\n');

      expect(watcher.changedFileUris(), [Uri.file(bPath).toString()]);
    });

    test('a file created after the snapshot counts as changed', () {
      writeFile(p.join('lib', 'a.dart'));
      final watcher = SourceWatcher(tmp.path);
      watcher.snapshot();

      writeFile(p.join('lib', 'new_file.dart'));
      final newPath = watcher.dartFiles().firstWhere(
        (f) => p.basename(f) == 'new_file.dart',
      );

      expect(watcher.changedFileUris(), [Uri.file(newPath).toString()]);
    });
    test('reports deleted files once and detects recreation', () {
      writeFile('lib/a.dart');
      final watcher = SourceWatcher(tmp.path)..snapshot();
      final path = p.join(tmp.path, 'lib/a.dart');
      File(path).deleteSync();
      expect(watcher.changedFileUris(), [Uri.file(path).toString()]);
      expect(watcher.changedFileUris(), isEmpty);
      writeFile('lib/a.dart');
      expect(watcher.changedFileUris(), [Uri.file(path).toString()]);
    });

    test('retries edited and deleted sources until successful', () {
      writeFile('lib/a.dart');
      writeFile('lib/b.dart');
      final watcher = SourceWatcher(tmp.path)..snapshot();
      writeFile('lib/a.dart', 'changed');
      File(p.join(tmp.path, 'lib/b.dart')).deleteSync();
      final first = watcher.changedFileUris();
      expect(first, hasLength(2));
      watcher.restoreInvalidations(first);
      final retry = watcher.changedFileUris();
      expect(retry, first);
      watcher.restoreInvalidations(retry);
      writeFile('lib/a.dart', 'another edit');
      writeFile('lib/c.dart');
      expect(watcher.changedFileUris(), hasLength(3));
      expect(watcher.changedFileUris(), isEmpty);
    });

    test('snapshot clears queued invalidations', () {
      writeFile('lib/a.dart');
      final watcher = SourceWatcher(tmp.path);
      watcher.restoreInvalidations(watcher.changedFileUris());
      watcher.snapshot();
      expect(watcher.changedFileUris(), isEmpty);
    });
  });
}
