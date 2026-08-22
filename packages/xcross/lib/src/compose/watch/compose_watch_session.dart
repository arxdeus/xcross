import 'dart:async';

import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/compose/watch/kotlin_source_watcher.dart';
import 'package:xcross/src/models/pack_result.dart';

/// Rebuild + reinstall + relaunch a Compose app, returning the new bundle.
typedef ComposeRebuild = Future<PackResult> Function();

/// Run one launch-and-supervise session; returns when the session ends.
typedef ComposeRunSession =
    Future<void> Function({
      required PackResult pack,
      required Future<bool> Function() onRestartRequested,
    });

/// Drives the Compose edit → rebuild → relaunch loop.
///
/// Kotlin/Native compiles Compose iOS apps ahead of time to a Mach-O binary,
/// so there is no equivalent of Flutter's `reloadSources`: JetBrains' own
/// Compose Hot Reload requires a JVM target and JetBrains Runtime class
/// redefinition, neither of which exists on device. The honest primitive is
/// therefore a *fast restart*: rebuild the framework, reinstall, and relaunch,
/// while keeping the terminal session, device selection, and RSD tunnel warm.
///
/// The expensive part is the Kotlin/Native compile (measured at ~133s of a
/// ~147s no-op edit cycle on a Compose sample), so the loop's one real
/// optimisation is refusing to rebuild when no watched source actually
/// changed.
final class ComposeWatchSession {
  ComposeWatchSession({
    required this.watcher,
    required this.rebuild,
    required this.runSession,
  });

  final KotlinSourceWatcher watcher;
  final ComposeRebuild rebuild;
  final ComposeRunSession runSession;

  /// Runs [pack] and then keeps relaunching it as long as restarts are
  /// requested. Returns once the user quits the session.
  Future<void> run(PackResult pack) async {
    var current = pack;
    watcher.snapshot();

    while (true) {
      PackResult? next;
      await runSession(
        pack: current,
        onRestartRequested: () async {
          next = await _rebuildIfChanged();
          return next != null;
        },
      );
      final rebuilt = next;
      if (rebuilt == null) return;
      current = rebuilt;
    }
  }

  /// Rebuild when sources changed. Returns null when nothing changed or the
  /// build failed, which keeps the current session alive rather than tearing
  /// down a working app for a build that produced nothing.
  Future<PackResult?> _rebuildIfChanged() async {
    final changed = watcher.changedFiles();
    if (changed.isEmpty) {
      Log.logInfo('No source changes ${Log.dim('— app left running')}');
      return null;
    }
    Log.logInfo(
      'Changed',
      '${changed.length} file${changed.length == 1 ? '' : 's'} '
          '${Log.dim('— rebuilding')}',
    );
    try {
      return await rebuild();
    } on Object catch (e) {
      Log.logError('Rebuild failed: $e');
      // The snapshot already advanced, so an unchanged retry would report
      // "no source changes" and silently do nothing. Force the next request
      // to rebuild even if the user only fixes the error and saves nothing
      // else.
      watcher.invalidate(changed);
      return null;
    }
  }
}
