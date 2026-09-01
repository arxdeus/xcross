import 'dart:io';

import 'package:cli_kit/cli_kit.dart';

/// Kill [process] together with everything it spawned.
abstract final class ProcessKill {
  /// [Process.kill] signals one pid only. On Windows that can leave AOT
  /// runtime children holding sockets; `taskkill /T` tears down the tree.
  static Future<void> killTree(Process process) async {
    if (!Platform.isWindows) {
      process.kill();
      return;
    }
    try {
      await ProcessRunner.run(await ProcessRunner.locateTool('taskkill'), [
        '/PID',
        '${process.pid}',
        '/T',
        '/F',
      ]);
    } on Object {
      // Best effort; the direct kill below still handles the parent.
    }
    process.kill();
  }
}
