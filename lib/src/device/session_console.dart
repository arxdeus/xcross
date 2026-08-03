import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/constants.dart';
import 'package:xcross_flutter/xcross_flutter.dart';

/// Interactive terminal session for an attached app: streams the app's stdout,
/// dispatches `r`/`R`/`q` keypresses to hot reload, and stops on SIGINT or when
/// the app exits.
class SessionConsole {
  SessionConsole({required this.gdb, required this.hotReload});

  final GdbRemoteClient gdb;
  final HotReloadController? hotReload;

  bool _stopped = false;

  /// Completes the moment [_stop] is first called; `run()` awaits this
  /// instead of busy-polling [_stopped].
  final Completer<void> _stoppedCompleter = Completer<void>();

  /// Prevents overlapping reload/restart operations.
  bool _busy = false;

  Completer<void>? _done;

  /// Signalled by [_stop] so [_drainGdbReplies] exits without waiting for the
  /// next GDB packet (which may never come after `q`).
  final Completer<void> _drainCancel = Completer<void>();

  /// Flip [_stopped] and complete [_stoppedCompleter] (idempotent).
  void _stop() {
    _stopped = true;
    if (!_stoppedCompleter.isCompleted) _stoppedCompleter.complete();
    if (!_drainCancel.isCompleted) _drainCancel.complete();
  }

  /// Run until the app exits or the user quits.
  Future<void> run() async {
    // Forward Ctrl-C cleanly; a second Ctrl-C hard-kills in case cleanup hangs.
    final signals = ProcessSignal.sigint.watch().listen((_) {
      if (_stopped) exit(130);
      _stop();
    });

    try {
      final drainFuture = _drainGdbReplies();
      final keypressFuture = _runKeypressLoop();

      await _stoppedCompleter.future;
      // Drain/keypress should already be unwinding via [_stop]; keep short
      // timeouts so a wedged stdin cancel cannot block process exit.
      await drainFuture.timeout(const Duration(seconds: 1), onTimeout: () {});
      await keypressFuture.timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
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
    try {
      stdout.add(bytes);
    } on Object catch (_) {
      // Stdout can be wedged on Windows AOT after console-mode churn; dropping
      // a chunk is better than hanging the drain loop forever.
    }
  }

  void _flushAppOutput() {
    for (final bytes in _heldOutput) {
      _writeAppOutput(bytes);
    }
    _heldOutput.clear();
  }

  /// Forward `O` (stdout) packets and stop on exit/termination.
  Future<void> _drainGdbReplies() async {
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final sub = gdb.replies.listen(
      (reply) {
        if (_stopped) {
          finish();
          return;
        }
        switch (reply.type) {
          case GdbReply.stdout:
            _writeAppOutput(reply.stdoutBytes);
          case GdbReply.exited || GdbReply.terminated:
            Log.logInfo('App exited ${Log.ansi.subtle('(${reply.payload})')}');
            _stop();
            finish();
          case GdbReply.stopped || GdbReply.other:
            break;
        }
      },
      onDone: finish,
      onError: (_) => finish(),
      cancelOnError: true,
    );

    // Exit as soon as either the stream ends or the user quits — don't sit on
    // `await for` forever with no more packets after `q`.
    await Future.any([done.future, _drainCancel.future]);
    try {
      await sub.cancel().timeout(const Duration(milliseconds: 500));
    } on Object catch (_) {}
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
      Log.logWarn(
        "could not enable raw stdin — press Enter after 'r'/'R', or check TTY",
      );
    }

    final done = _done = Completer<void>();
    // _stopped must flip BEFORE _finish(): run()'s `while (!_stopped)` loop
    // would otherwise spin forever when our stdin pipe closes, orphaning
    // frontend_server and the RSD tunnel.
    // ProcessRunner.sharedStdin, not stdin: cancelling an earlier raw stdin
    // subscription leaves this listen dead on arrival — onDone fires at once
    // and the session quits the moment the app launches.
    final sub = ProcessRunner.sharedStdin.listen(
      _handleKeyByte,
      onDone: () {
        _stop();
        _finish();
      },
      onError: (_) {
        _stop();
        _finish();
      },
    );

    // Break out promptly when stopped externally (e.g. SIGINT), since the stdin
    // subscription otherwise keeps the event loop alive and blocks exit.
    final poll = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (_stopped) {
        t.cancel();
        _finish();
      }
    });

    await done.future;
    poll.cancel();
    try {
      await sub.cancel().timeout(const Duration(milliseconds: 500));
    } on Object catch (_) {}
    _restoreCookedStdin();
  }

  /// Put stdin into cbreak/raw-ish mode so a single keypress is delivered
  /// without Enter. Returns whether both mode flags were applied successfully.
  ///
  /// Order matches Flutter tools / dart-lang#28599: echoMode off first, then
  /// lineMode (Windows rejects lineMode=false while echo is still on).
  static bool _enableRawStdin() {
    // A pipe already delivers bytes unbuffered, and setting the terminal modes
    // on one throws — warning about it would be a warning for a non-problem.
    if (!stdin.hasTerminal) return true;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
      // Verify — a silent no-op leaves "keys do nothing" with no clue why.
      if (stdin.echoMode || stdin.lineMode) {
        Log.logWarn(
          'stdin still cooked after raw request '
          '(echo=${stdin.echoMode}, line=${stdin.lineMode})',
        );
        return false;
      }
      return true;
    } on Object catch (e) {
      Log.logWarn('stdin raw mode failed: $e');
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
          ch == DeviceConstants.keyBigQ ||
          ch == DeviceConstants.keyCtrlC ||
          ch == DeviceConstants.keyCtrlD) {
        Log.logInfo('Quitting');
        _stop();
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
    final step = Log.beginStep('Hot reload');
    try {
      final ok = await controller.reload();
      if (ok) {
        step.done('Reloaded');
      } else {
        step.fail("Reload rejected (try 'R' to restart)");
      }
    } catch (e) {
      step.fail('Hot reload failed');
      Log.logError('$e');
    }
  }

  Future<void> _handleHotRestart() async {
    final controller = hotReload;
    if (controller == null) return;
    final step = Log.beginStep('Hot restart');
    try {
      await controller.restart();
      step.done('Restarted');
    } catch (e) {
      step.fail('Hot restart failed');
      Log.logError('$e');
    }
  }
}
