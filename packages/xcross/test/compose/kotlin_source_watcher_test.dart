import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/watch/kotlin_source_watcher.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('xcross_kt_watch'));
  tearDown(() => root.deleteSync(recursive: true));

  File write(String relative, String contents) {
    final file = File(p.join(root.path, relative))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
    return file;
  }

  test('collects Kotlin and Gradle sources', () {
    write('shared/src/commonMain/kotlin/App.kt', 'fun main() {}');
    write('shared/build.gradle.kts', 'plugins {}');
    write('gradle/libs.versions.toml', '[versions]');
    write('README.md', 'not a source');

    final names = KotlinSourceWatcher(
      root.path,
    ).sourceFiles().map(p.basename).toSet();

    expect(names, contains('App.kt'));
    expect(names, contains('build.gradle.kts'));
    expect(names, contains('libs.versions.toml'));
    expect(names, isNot(contains('README.md')));
  });

  test('ignores build output directories', () {
    write('shared/src/commonMain/kotlin/App.kt', 'fun main() {}');
    // Gradle rewrites these on every build; treating them as sources would
    // make every check report a change and trigger endless rebuilds.
    write('build/generated/Generated.kt', 'generated');
    write('shared/build/tmp/Other.kt', 'generated');
    write('.gradle/cache.properties', 'x=1');

    final files = KotlinSourceWatcher(root.path).sourceFiles();

    expect(files, hasLength(1));
    expect(p.basename(files.single), 'App.kt');
  });

  test('detects edits, additions, and deletions', () {
    final app = write('shared/src/App.kt', 'fun main() {}');
    final watcher = KotlinSourceWatcher(root.path)..snapshot();

    expect(watcher.changedFiles(), isEmpty);

    app.writeAsStringSync('fun main() { println("hi") }');
    expect(watcher.changedFiles().map(p.basename), ['App.kt']);
    expect(watcher.changedFiles(), isEmpty, reason: 'baseline advanced');

    write('shared/src/Extra.kt', 'val x = 1');
    expect(watcher.changedFiles().map(p.basename), ['Extra.kt']);

    app.deleteSync();
    expect(watcher.changedFiles().map(p.basename), ['App.kt']);
    expect(watcher.changedFiles(), isEmpty);
  });

  test('rewriting identical content is not a change', () {
    final app = write('shared/src/App.kt', 'fun main() {}');
    final watcher = KotlinSourceWatcher(root.path)..snapshot();

    // Editors and formatters rewrite files wholesale, which bumps mtime
    // without changing content; a rebuild here costs ~2 minutes.
    app.writeAsStringSync('fun main() {}');

    expect(watcher.changedFiles(), isEmpty);
  });

  test('invalidate forces the next check to report a change again', () {
    final app = write('shared/src/App.kt', 'fun main() {}');
    final watcher = KotlinSourceWatcher(root.path)..snapshot();
    app.writeAsStringSync('broken');
    final changed = watcher.changedFiles();
    expect(changed, isNotEmpty);

    // After a failed build the baseline has already advanced, so without
    // invalidate a retry would report "no changes" and skip the rebuild.
    watcher.invalidate(changed);

    expect(watcher.changedFiles().map(p.basename), ['App.kt']);
  });

  test('hasChanges reports the same signal as changedFiles', () {
    final app = write('shared/src/App.kt', 'fun main() {}');
    final watcher = KotlinSourceWatcher(root.path)..snapshot();

    expect(watcher.hasChanges(), isFalse);
    app.writeAsStringSync('fun main() { }');
    expect(watcher.hasChanges(), isTrue);
    expect(watcher.hasChanges(), isFalse);
  });

  test('a missing project root yields no sources instead of throwing', () {
    final watcher = KotlinSourceWatcher(p.join(root.path, 'nope'))..snapshot();
    expect(watcher.sourceFiles(), isEmpty);
    expect(watcher.changedFiles(), isEmpty);
  });
}
