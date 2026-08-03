import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross_flutter/src/hot_reload/source_watcher.dart';
import 'package:xcross_flutter/src/models/hot_reload_config.dart';

/// [SourceWatcher] only reads [HotReloadConfig.projectRoot]; the rest of the
/// required fields are irrelevant here, so fill them with dummy values.
HotReloadConfig _configFor(String projectRoot) => HotReloadConfig(
  dart: 'x',
  frontendServer: 'x',
  sdkRoot: 'x',
  packageConfig: 'x',
  entrypoint: 'x',
  projectRoot: projectRoot,
  outputDill: 'x',
);

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

      final watcher = SourceWatcher(_configFor(tmp.path));
      final basenames = watcher.dartFiles().map(p.basename).toSet();

      expect(basenames, {'a.dart', 'b.dart'});
    });

    test('returns absolute paths', () {
      writeFile(p.join('lib', 'a.dart'));
      final watcher = SourceWatcher(_configFor(tmp.path));
      final files = watcher.dartFiles();
      expect(files, hasLength(1));
      expect(p.isAbsolute(files.single), isTrue);
    });

    test('falls back to projectRoot itself when lib/ does not exist', () {
      writeFile('other.dart'); // no lib/ dir at all
      final watcher = SourceWatcher(_configFor(tmp.path));
      final basenames = watcher.dartFiles().map(p.basename).toSet();
      expect(basenames, {'other.dart'});
    });

    test('returns an empty list when projectRoot does not exist', () {
      final missing = p.join(tmp.path, 'does_not_exist');
      final watcher = SourceWatcher(_configFor(missing));
      expect(watcher.dartFiles(), isEmpty);
    });
  });

  group('snapshot / changedFileUris', () {
    test('reports nothing changed right after a snapshot', () {
      writeFile(p.join('lib', 'a.dart'));
      final watcher = SourceWatcher(_configFor(tmp.path));
      watcher.snapshot();
      expect(watcher.changedFileUris(), isEmpty);
    });

    // Regression check for the documented "not pure" contract: the first
    // call must report the edit, and — because it also advances the
    // baseline — an immediate second call with no further edits must not.
    test('reports an edited file once, then advances the baseline', () {
      writeFile(p.join('lib', 'a.dart'));
      final watcher = SourceWatcher(_configFor(tmp.path));
      final aPath = watcher.dartFiles().single;
      watcher.snapshot();

      File(aPath).writeAsStringSync('// changed\n');

      expect(watcher.changedFileUris(), [Uri.file(aPath).toString()]);
      expect(watcher.changedFileUris(), isEmpty);
    });

    test('only reports the file that actually changed', () {
      writeFile(p.join('lib', 'a.dart'), '// a\n');
      writeFile(p.join('lib', 'b.dart'), '// b\n');
      final watcher = SourceWatcher(_configFor(tmp.path));
      watcher.snapshot();

      final bPath = watcher.dartFiles().firstWhere(
        (f) => p.basename(f) == 'b.dart',
      );
      File(bPath).writeAsStringSync('// b changed\n');

      expect(watcher.changedFileUris(), [Uri.file(bPath).toString()]);
    });

    test('a file created after the snapshot counts as changed', () {
      writeFile(p.join('lib', 'a.dart'));
      final watcher = SourceWatcher(_configFor(tmp.path));
      watcher.snapshot();

      writeFile(p.join('lib', 'new_file.dart'));
      final newPath = watcher.dartFiles().firstWhere(
        (f) => p.basename(f) == 'new_file.dart',
      );

      expect(watcher.changedFileUris(), [Uri.file(newPath).toString()]);
    });
  });
}
