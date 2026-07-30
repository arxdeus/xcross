import 'dart:async';
import 'dart:io';

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/gdb_remote_client.dart';
import 'package:xcross/src/device/hot_reload_controller.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Interactive terminal session for an attached app: streams the app's stdout,
/// dispatches `r`/`R`/`q` keypresses to hot reload, and stops on SIGINT or when
/// the app exits.
class SessionConsole {
  SessionConsole({required this.gdb, required this.hotReload});

  final GdbRemoteClient gdb;
  final HotReloadController? hotReload;

  bool _stopped = false;

  /// Prevents overlapping reload/restart operations.
  bool _busy = false;

  Completer<void>? _done;

  /// Run until the app exits or the user quits.
  Future<void> run() async {
    // Forward Ctrl-C cleanly; a second Ctrl-C hard-kills in case cleanup hangs.
    final signals = ProcessSignal.sigint.watch().listen((_) {
      if (_stopped) exit(130);
      _stopped = true;
    });

    try {
      final drainFuture = _drainGdbReplies();
      final keypressFuture = _runKeypressLoop();

      while (!_stopped) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await drainFuture.timeout(const Duration(seconds: 2), onTimeout: () {});
      await keypressFuture.timeout(const Duration(seconds: 1),
          onTimeout: () {});
    } finally {
      // An uncancelled signal subscription keeps the event loop alive forever;
      // bin/xcross.dart only sets exitCode, so a clean 'q' would never return.
      // In a finally so a gdb socket error still lets the caller clean up.
      await signals.cancel();
    }
  }

  /// App output that arrived while a reload spinner was on screen. Writing it
  /// straight to fd1 would shred the spinner block, so it waits its turn.
  final List<List<int>> _heldOutput = [];

  void _writeAppOutput(List<int> bytes) {
    if (_busy) {
      _heldOutput.add(bytes);
      return;
    }
    stdout.add(bytes);
  }

  void _flushAppOutput() {
    for (final bytes in _heldOutput) {
      stdout.add(bytes);
    }
    _heldOutput.clear();
  }

  /// Forward `O` (stdout) packets and stop on exit/termination.
  Future<void> _drainGdbReplies() async {
    await for (final reply in gdb.replies) {
      if (_stopped) break;
      switch (reply.type) {
        case GdbReply.stdout:
          _writeAppOutput(reply.stdoutBytes);
        case GdbReply.exited || GdbReply.terminated:
          logInfo('App exited ${ansi.subtle('(${reply.payload})')}');
          _stopped = true;
          return;
        case GdbReply.stopped || GdbReply.other:
          break;
      }
    }
  }

  void _finish() {
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Reads control keys from stdin. Deliberately does NOT require a TTY: the
  /// DAP adapter drives the same `r`/`R`/`q` protocol over a pipe.
  Future<void> _runKeypressLoop() async {
    // EOF means "controller went away" only when the DAP owns our stdin pipe.
    // Without any controller (CI, docker without -i, `< /dev/null`, nohup)
    // stdin is at EOF from the start and must not stop the session.
    if (!stdin.hasTerminal && Platform.environment['XCROSS_DAP'] != '1') return;

    // Never swallow failures: silent cooked mode looks like "keys do nothing".
    if (!_enableRawStdin()) {
      logWarn(
          "could not enable raw stdin — press Enter after 'r'/'R', or check TTY");
    }

    final done = _done = Completer<void>();
    // _stopped must flip BEFORE _finish(): run()'s `while (!_stopped)` loop
    // would otherwise spin forever when our stdin pipe closes, orphaning
    // frontend_server and the RSD tunnel.
    // sharedStdin, not stdin: `xtool install` reads stdin too, and cancelling
    // a raw stdin subscription leaves this listen dead on arrival — onDone
    // fires at once and the session quits the moment the app launches.
    final sub = sharedStdin.listen(
      _handleKeyByte,
      onDone: () {
        _stopped = true;
        _finish();
      },
      onError: (_) {
        _stopped = true;
        _finish();
      },
    );

    // Break out promptly when stopped externally (e.g. SIGINT), since the stdin
    // subscription otherwise keeps the event loop alive and blocks exit.
    final poll = Timer.periodic(const Duration(milliseconds: 150), (t) {
      if (_stopped) {
        t.cancel();
        _finish();
      }
    });

    await done.future;
    poll.cancel();
    await sub.cancel();
    _restoreCookedStdin();
  }

  /// Put stdin into cbreak/raw-ish mode so a single keypress is delivered
  /// without Enter. Returns whether both mode flags were applied successfully.
  ///
  /// Order matches Flutter tools: echoMode then lineMode when enabling;
  /// reverse when restoring (important on Windows / some PTYs).
  static bool _enableRawStdin() {
    // A pipe already delivers bytes unbuffered, and setting the terminal modes
    // on one throws — warning about it would be a warning for a non-problem.
    if (!stdin.hasTerminal) return true;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
      return true;
    } on Object catch (e) {
      logWarn('stdin raw mode failed: $e');
      return false;
    }
  }

  static void _restoreCookedStdin() {
    if (!stdin.hasTerminal) return;
    try {
      stdin.lineMode = true;
      stdin.echoMode = true;
    } on Object catch (_) {}
  }

  /// Handle a single raw [bytes] chunk from stdin. Quit keys stop the session;
  /// reload/restart keys are dispatched only when no op is already in flight.
  Future<void> _handleKeyByte(List<int> bytes) async {
    for (final ch in bytes) {
      if (_stopped) return _finish();
      if (ch == DeviceConstants.keyQ ||
          ch == DeviceConstants.keyCtrlC ||
          ch == DeviceConstants.keyCtrlD) {
        _stopped = true;
        return _finish();
      }
      // Ignore reload/restart keys while one is already in flight so presses
      // don't overlap and corrupt frontend_server state.
      if (_busy) continue;
      if (ch == DeviceConstants.keyR) {
        _busy = true;
        await _handleHotReload();
        _busy = false;
        _flushAppOutput();
      } else if (ch == DeviceConstants.keyBigR) {
        _busy = true;
        await _handleHotRestart();
        _busy = false;
        _flushAppOutput();
      }
    }
  }

  Future<void> _handleHotReload() async {
    final controller = hotReload;
    if (controller == null) return;
    final step = beginStep('Hot reload');
    try {
      final ok = await controller.reload();
      if (ok) {
        step.done('Reloaded');
      } else {
        step.fail("Reload rejected (try 'R' to restart)");
      }
    } catch (e) {
      step.fail('Hot reload failed');
      logError('$e');
    }
  }

  Future<void> _handleHotRestart() async {
    final controller = hotReload;
    if (controller == null) return;
    final step = beginStep('Hot restart');
    try {
      await controller.restart();
      step.done('Restarted');
    } catch (e) {
      step.fail('Hot restart failed');
      logError('$e');
    }
  }
}
