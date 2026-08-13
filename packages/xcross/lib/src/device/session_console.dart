import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:meta/meta.dart';
import 'package:pure/pure.dart';
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/flutter/flutter.dart';

/// Interactive terminal session for an attached app: streams the app's stdout,
/// dispatches `r`/`R`/`q` keypresses to hot reload, and stops on SIGINT or when
/// the app exits.
final class SessionConsole {
  SessionConsole({
    required this.gdb,
    required this.hotReload,
    this.hotReloadUnavailable,
    this.onRestartRequested,
  });

  /// Drain and keypress loops are already unwinding via [_stop] by the time we
  /// await them; this only bounds a wedged stdin cancel that would otherwise
  /// block process exit.
  static const _unwindTimeout = Duration(seconds: 1);

  final GdbRemoteClient gdb;
  final HotReloadController? hotReload;

  /// Rebuild-and-relaunch hook for runtimes without in-place hot reload
  /// (Kotlin/Native Compose is AOT-compiled, so `r` can only mean "build the
  /// new binary and restart the app").
  ///
  /// Returning `true` means the session should end so the caller can relaunch;
  /// `false` keeps the current session running (e.g. the build failed).
  final Future<bool> Function()? onRestartRequested;

  /// Why [hotReload] is null, shown when `r`/`R` are pressed anyway.
  ///
  /// A key that does nothing at all reads as a broken terminal, so the session
  /// answers every press even when it has nothing to reload.
  final String? hotReloadUnavailable;

  /// Completes the moment [_stop] is first called. `run()` awaits it instead of
  /// polling, and [_drainGdbReplies] uses it to bail out without waiting for a
  /// next GDB packet (which may never come after `q`).
  final Completer<void> _stoppedCompleter = Completer<void>();

  /// App output that arrived while a reload spinner was on screen. Writing it
  /// straight to fd1 would shred the spinner block, so it waits its turn.
  final List<List<int>> _heldOutput = [];

  /// Prevents overlapping reload/restart operations.
  bool _busy = false;

  Completer<void>? _keypressDone;

  bool get _stopped => _stoppedCompleter.isCompleted;

  /// Signal every loop to unwind (idempotent).
  void _stop() {
    if (!_stoppedCompleter.isCompleted) _stoppedCompleter.complete();
  }

  void _finishKeypressLoop() {
    final done = _keypressDone;
    if (done != null && !done.isCompleted) done.complete();
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
      await drainFuture.timeout(_unwindTimeout, onTimeout: nothing);
      await keypressFuture.timeout(_unwindTimeout, onTimeout: nothing);
    } finally {
      // An uncancelled signal subscription keeps the event loop alive forever;
      // bin/xcross.dart only sets exitCode, so a clean 'q' would never return.
      // In a finally so a gdb socket error still lets the caller clean up.
      await signals.cancel();
    }
  }

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
          case GdbReply.stopped:
            // A crash arrives as a T-packet, not as W/X: the process is
            // stopped, not gone. Ignoring it (the old behaviour) left the
            // app frozen on a black screen with no output at all, which is
            // indistinguishable from a hang. Report it and end the session.
            if (reply.isFatalStop) {
              Log.logError(
                'App crashed: ${reply.stopDescription}. '
                'The process is stopped at the fault.',
              );
              _stop();
              finish();
            }
          case GdbReply.other:
            break;
        }
      },
      onDone: finish,
      onError: (_) => finish(),
      cancelOnError: true,
    );

    // Exit as soon as either the stream ends or the user quits — don't sit on
    // `await for` forever with no more packets after `q`.
    await Future.any([done.future, _stoppedCompleter.future]);
    try {
      await sub.cancel().timeout(const Duration(milliseconds: 500));
    } on Object catch (_) {}
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

    final done = _keypressDone = Completer<void>();
    // _stop() must run BEFORE _finishKeypressLoop(): the session must observe
    // "stopped" when our stdin pipe closes, or frontend_server and the RSD
    // tunnel are orphaned while run() waits on a stop that never comes.
    // ProcessRunner.sharedStdin, not stdin: cancelling an earlier raw stdin
    // subscription leaves this listen dead on arrival — onDone fires at once
    // and the session quits the moment the app launches.
    final sub = ProcessRunner.sharedStdin.listen(
      handleKeyByte,
      onDone: () {
        _stop();
        _finishKeypressLoop();
      },
      onError: (_) {
        _stop();
        _finishKeypressLoop();
      },
    );

    // Break out promptly when stopped externally (e.g. SIGINT), since the stdin
    // subscription otherwise keeps the event loop alive and blocks exit.
    final poll = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (_stopped) {
        t.cancel();
        _finishKeypressLoop();
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
  /// reload/restart keys are ignored while one is already in flight, so presses
  /// don't overlap and corrupt frontend_server state.
  @visibleForTesting
  Future<void> handleKeyByte(List<int> bytes) async {
    for (final ch in bytes) {
      if (_stopped) return _finishKeypressLoop();
      switch (ch) {
        case DeviceConstants.keyQ ||
            DeviceConstants.keyBigQ ||
            DeviceConstants.keyCtrlC ||
            DeviceConstants.keyCtrlD:
          Log.logInfo('Quitting');
          _stop();
          return _finishKeypressLoop();
        case DeviceConstants.keyR || DeviceConstants.keyBigR
            when !_busy && onRestartRequested != null:
          await _runExclusive(_handleRestartRequest);
        case DeviceConstants.keyR when !_busy:
          await _runExclusive(_handleHotReload);
        case DeviceConstants.keyBigR when !_busy:
          await _runExclusive(_handleHotRestart);
      }
    }
  }

  Future<void> _runExclusive(Future<void> Function() operation) async {
    _busy = true;
    await operation();
    _busy = false;
    _flushAppOutput();
  }

  void _reportHotReloadUnavailable() => Log.logWarn(
    hotReloadUnavailable ?? 'hot reload is not available in this session.',
  );

  /// Ask the owner to rebuild and relaunch, then end this session when it
  /// agrees. The console cannot relaunch by itself: the app's process, the
  /// debugger attachment, and the install all belong to the caller.
  Future<void> _handleRestartRequest() async {
    final handler = onRestartRequested;
    if (handler == null) return;
    if (await handler()) {
      _stop();
      _finishKeypressLoop();
    }
  }

  Future<void> _handleHotReload() async {
    final controller = hotReload;
    if (controller == null) return _reportHotReloadUnavailable();
    final step = Log.beginStep('Hot reload');
    try {
      if (await controller.reload()) {
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
    if (controller == null) return _reportHotReloadUnavailable();
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
