import 'dart:io';

import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Thin helpers for interactive `sudo -v` and locating the `sudo` binary.
abstract final class Sudo {
  /// Absolute path to `sudo`, or null if not on PATH.
  static Future<String?> resolve() => Platform.isWindows
      ? Future<String?>.value()
      : ProcessRunner.which('sudo');

  /// Prompt once via `sudo -v` (inheritStdio) so later `sudo -n …` calls can
  /// run without holding the TTY open.
  ///
  /// No-op when `sudo` is not available (already root / passwordless path).
  static Future<void> cacheCredentials({String? manualHint}) async {
    final sudo = await resolve();
    if (sudo == null) return;

    Log.logInfo(
      'Confirming sudo access '
      '${Log.ansi.subtle('— you may be asked for your password once')}',
    );
    final proc = await Process.start(sudo, const [
      '-v',
    ], mode: ProcessStartMode.inheritStdio);
    final code = await proc.exitCode;
    if (code != 0) {
      final hint = manualHint ?? 'Retry with an interactive sudo session.';
      throw XcrossError('sudo authentication failed (exit $code).\n$hint');
    }
  }
}
