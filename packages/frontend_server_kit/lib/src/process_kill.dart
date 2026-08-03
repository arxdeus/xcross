import 'dart:io';

/// Kill [process] together with everything it spawned.
abstract final class ProcessKill {
  /// [Process.kill] signals one pid only. On Windows that can leave AOT runtime
  /// children holding sockets; `taskkill /T` tears down the tree.
  static Future<void> killTree(Process process) async {
    if (!Platform.isWindows) {
      process.kill();
      return;
    }
    try {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } on Object {
      // taskkill missing or the tree is already gone — fall through.
    }
    process.kill();
  }
}
