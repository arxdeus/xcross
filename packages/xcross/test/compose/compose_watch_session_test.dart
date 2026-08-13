import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/watch/compose_watch_session.dart';
import 'package:xcross/src/compose/watch/kotlin_source_watcher.dart';
import 'package:xcross/src/models/pack_result.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('xcross_watch'));
  tearDown(() => root.deleteSync(recursive: true));

  File writeSource(String contents) {
    final file = File(p.join(root.path, 'shared', 'src', 'App.kt'))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
    return file;
  }

  PackResult packAt(String path) =>
      PackResult(outputPath: path, bundleId: 'com.example.app');

  test('quitting the session ends the loop without rebuilding', () async {
    writeSource('fun main() {}');
    var builds = 0;
    var sessions = 0;

    await ComposeWatchSession(
      watcher: KotlinSourceWatcher(root.path),
      rebuild: () async {
        builds++;
        return packAt('/build/App.app');
      },
      // A session that returns without asking for a restart models the user
      // pressing `q`.
      runSession: ({required pack, required onRestartRequested}) async {
        sessions++;
      },
    ).run(packAt('/build/App.app'));

    expect(sessions, 1);
    expect(builds, isZero);
  });

  test('a restart with edits rebuilds and relaunches the new bundle', () async {
    final source = writeSource('fun main() {}');
    final launched = <String>[];
    var builds = 0;

    await ComposeWatchSession(
      watcher: KotlinSourceWatcher(root.path),
      rebuild: () async {
        builds++;
        return packAt('/build/App-$builds.app');
      },
      runSession: ({required pack, required onRestartRequested}) async {
        launched.add(pack.outputPath);
        if (launched.length > 2) return;
        source.writeAsStringSync('fun main() { ${launched.length} }');
        await onRestartRequested();
      },
    ).run(packAt('/build/App-0.app'));

    expect(builds, 2);
    expect(launched, [
      '/build/App-0.app',
      '/build/App-1.app',
      '/build/App-2.app',
    ]);
  });

  test('no source changes keeps the running app and skips the build', () async {
    writeSource('fun main() {}');
    var builds = 0;
    var restartAccepted = true;
    var sessions = 0;

    await ComposeWatchSession(
      watcher: KotlinSourceWatcher(root.path),
      rebuild: () async {
        builds++;
        return packAt('/build/App.app');
      },
      runSession: ({required pack, required onRestartRequested}) async {
        sessions++;
        // Nothing was edited, so the request must be refused: a ~2 minute
        // Kotlin/Native rebuild for an unchanged tree is pure waste, and
        // tearing down a working app for it is worse.
        restartAccepted = await onRestartRequested();
      },
    ).run(packAt('/build/App.app'));

    expect(restartAccepted, isFalse);
    expect(builds, isZero);
    expect(sessions, 1);
  });

  test(
    'a failed rebuild keeps the session and retries the same files',
    () async {
      final source = writeSource('fun main() {}');
      var attempts = 0;
      final accepted = <bool>[];

      await ComposeWatchSession(
        watcher: KotlinSourceWatcher(root.path),
        rebuild: () async {
          attempts++;
          if (attempts == 1) throw const FormatException('compile error');
          return packAt('/build/App-fixed.app');
        },
        runSession: ({required pack, required onRestartRequested}) async {
          if (accepted.isNotEmpty) return;
          source.writeAsStringSync('fun main() { broken }');
          accepted.add(await onRestartRequested());
          // The retry does not touch the file again: a failed build must not
          // consume the change, or the fix would look like "no changes".
          accepted.add(await onRestartRequested());
        },
      ).run(packAt('/build/App.app'));

      expect(accepted, [false, true]);
      expect(attempts, 2);
    },
  );
}
