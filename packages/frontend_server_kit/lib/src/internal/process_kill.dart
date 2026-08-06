import 'dart:io';

/// Kill [process] together with everything it spawned.
abstract final class ProcessKill {
  /// [Process.kill] signals one pid only. On Windows that can leave AOT
  /// runtime children holding sockets; `taskkill /T` tears down the tree.
  static Future<void> killTree(Process process) async {
    if (!Platform.isWindows) {
      process.kill();
      return;
    }
    await Process.run('taskkill', [
      '/PID',
      '${process.pid}',
      '/T',
      '/F',
    ]).catchError((Object _) => ProcessResult(0, 1, '', ''));
    process.kill();
  }
}
