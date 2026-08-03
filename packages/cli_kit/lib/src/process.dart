import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/src/errors.dart';
import 'package:cli_kit/src/logging.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

/// Captured result of a finished subprocess.
class CapturedProcess {
  CapturedProcess(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Thin wrappers around `dart:io` [Process] with consistent UTF-8 decoding and
/// error reporting.
abstract final class ProcessRunner {
  /// Every stdin reader in the process must go through this one broadcast.
  ///
  /// Cancelling a subscription to [stdin] closes the underlying fd for good: a
  /// later `stdin.listen` then fires `onDone` immediately instead of
  /// delivering keys, which silently killed the hot-reload keypress loop
  /// after an install. `onCancel`/`onListen` pause and resume the source
  /// instead of tearing it down, so bytes typed between readers stay queued
  /// in the tty.
  static Stream<List<int>> get sharedStdin =>
      _sharedStdin ??= pausingBroadcast(stdin);
  static Stream<List<int>>? _sharedStdin;

  /// A broadcast view of [source] that pauses — never cancels — the source
  /// subscription when its last listener goes away, so a later listener still
  /// gets events. Split out from [sharedStdin] so it is testable without a
  /// tty.
  static Stream<T> pausingBroadcast<T>(Stream<T> source) =>
      source.asBroadcastStream(
        onListen: (sub) {
          if (sub.isPaused) sub.resume();
        },
        onCancel: (sub) => sub.pause(),
      );

  /// Run [executable] to completion, capturing stdout/stderr as UTF-8 strings.
  static Future<CapturedProcess> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return CapturedProcess(
      result.exitCode,
      result.stdout as String,
      result.stderr as String,
    );
  }

  /// Run [executable], throwing [CliError] on a non-zero exit code.
  ///
  /// When [tail] is given, output is streamed into that step's collapsing grey
  /// log and this process's stdin is forwarded to the child, so prompts still
  /// work. Otherwise, when [inheritStdio] is true the child shares this
  /// process's stdio via [ProcessStartMode.inheritStdio]. In the default case
  /// output is captured and the stderr is included in the thrown error.
  static Future<void> runChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool inheritStdio = false,
    String? label,
    Step? tail,
    // When [tail] streams output, stdin is forwarded by default so interactive
    // children (apt, sudo prompts) still work. Install/build steps that never
    // prompt must pass false: the first sharedStdin listen happens in cooked
    // mode and on Windows leaves the later hot-reload keypress loop deaf.
    bool forwardStdin = true,
  }) async {
    final prefix = label ?? executable;
    Log.logTrace('[$prefix] running: ${commandLine(executable, arguments)}');

    if (tail != null) {
      return _runWithTail(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        tail: tail,
        forwardStdin: forwardStdin,
      );
    }

    if (inheritStdio) {
      // Must use inheritStdio (not piped stdout/stderr) for interactive tools
      // that write prompts without a trailing newline and read stdin. Piping +
      // LineSplitter would hide the prompt and leave stdin disconnected.
      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        mode: ProcessStartMode.inheritStdio,
      );
      final code = await process.exitCode;
      if (code != 0) {
        throw CliError(
          'command failed ($code): ${commandLine(executable, arguments)}',
        );
      }
      return;
    }

    final result = await run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    if (result.exitCode != 0) {
      // Some tools (e.g. `swift build`) write their actual diagnostics to
      // stdout and only dynamic-linker/loader noise to stderr — dropping
      // stdout here silently hid the real error behind harmless warnings.
      final output = [
        result.stdout,
        result.stderr,
      ].where((s) => s.trim().isNotEmpty).join('\n');
      throw CliError(
        'command failed (${result.exitCode}): '
        '${commandLine(executable, arguments)}\n$output',
      );
    }
  }

  /// Stream a child's merged output into [tail]. Optionally forward our stdin
  /// so interactive prompts still work.
  static Future<void> _runWithTail(
    String executable,
    List<String> arguments, {
    required Step tail,
    String? workingDirectory,
    Map<String, String>? environment,
    bool forwardStdin = true,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );

    // Keep the full text for the error message; the step only shows the last
    // few lines. utf8.decoder as a stream transformer is chunk-boundary safe.
    final captured = StringBuffer();
    void sink(String chunk) {
      captured.write(chunk);
      tail.log(chunk);
    }

    final drained = Future.wait([
      process.stdout.transform(utf8.decoder).forEach(sink),
      process.stderr.transform(utf8.decoder).forEach(sink),
    ]);

    // A byte forwarded just as the child exits fails on the closed pipe, and
    // an IOSink reports that on `done` — unhandled, it takes down the process.
    unawaited(process.stdin.done.catchError((Object _) {}));

    StreamSubscription<List<int>>? input;
    if (forwardStdin) {
      try {
        input = sharedStdin.listen((bytes) {
          try {
            process.stdin.add(bytes);
          } on Object catch (_) {
            // Child already gone; nothing left to feed.
          }
        }, onError: (Object _) {});
      } on Object catch (e) {
        // Unavailable stdin is not fatal: the child simply gets no input,
        // exactly as before this streaming path existed.
        Log.logTrace('stdin not forwarded to $executable: $e');
      }
    } else {
      // Don't leave the child blocking on a pipe we will never write.
      try {
        await process.stdin.close();
      } on Object catch (_) {}
    }

    try {
      final code = await process.exitCode;
      // Stop forwarding the moment the child is gone, before its pipe errors.
      await input?.cancel();
      input = null;
      await drained;
      if (code != 0) {
        throw CliError(
          'command failed ($code): ${commandLine(executable, arguments)}\n'
          '$captured',
        );
      }
    } finally {
      await input?.cancel();
      unawaited(process.stdin.close().catchError((Object _) {}));
    }
  }

  static final _shellSpecialCharsPattern = RegExp(r'''[\s'"\\$`]''');

  /// Shell-like command rendering for logs and errors.
  static String commandLine(String executable, List<String> arguments) =>
      [executable, ...arguments].map(_shellQuote).join(' ');

  static String _shellQuote(String s) {
    if (s.isEmpty) return "''";
    if (!_shellSpecialCharsPattern.hasMatch(s)) return s;
    return "'${s.replaceAll("'", r"'\''")}'";
  }

  /// Host-specific filename for a bundled executable.
  static String hostExecutableName(
    String name, {
    bool? windows,
    String windowsExtension = '.exe',
  }) {
    final onWindows = windows ?? Platform.isWindows;
    return onWindows && p.extension(name).isEmpty
        ? '$name$windowsExtension'
        : name;
  }

  /// True when [path] is one of swiftly's proxy shims — every tool in
  /// swiftly's bin directory is a symlink to the `swiftly` binary itself,
  /// which re-execs the matching tool from the active Swift toolchain.
  static bool isSwiftlyProxy(String path) {
    try {
      final target = File(path).resolveSymbolicLinksSync();
      return p.basenameWithoutExtension(target) == 'swiftly';
    } on FileSystemException {
      return false;
    }
  }

  /// Absolute path to [name] on PATH, or null if not found.
  ///
  /// Windows lookup follows PATHEXT, matching `cmd.exe` and normal Python/
  /// Flutter installations where only `.exe`/`.bat` launchers exist.
  ///
  /// [accept] rejects candidates that exist but are not usable, so the search
  /// continues down PATH instead of stopping at the first name match.
  static Future<String?> which(
    String name, {
    Map<String, String>? environment,
    bool? windows,
    bool Function(String path)? accept,
  }) async {
    final env = environment ?? Platform.environment;
    final onWindows = windows ?? Platform.isWindows;
    final pathEnv = _environmentValue(env, 'PATH') ?? '';
    final extensions = onWindows
        ? (_environmentValue(env, 'PATHEXT') ?? '.COM;.EXE;.BAT;.CMD')
              .split(';')
              .where((extension) => extension.isNotEmpty)
              .map(
                (extension) =>
                    extension.startsWith('.') ? extension : '.$extension',
              )
              .toList()
        : const <String>[];
    final hasWindowsExtension = extensions.any(
      (extension) => name.toLowerCase().endsWith(extension.toLowerCase()),
    );
    final names = [
      name,
      if (onWindows && !hasWindowsExtension)
        for (final extension in extensions) '$name$extension',
    ];
    for (final dir in pathEnv.split(onWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      for (final candidateName in names) {
        final candidate = p.join(dir, candidateName);
        if (File(candidate).existsSync() &&
            (accept == null || accept(candidate))) {
          return candidate;
        }
      }
    }
    return null;
  }

  static String? _environmentValue(Map<String, String> env, String name) {
    final exact = env[name];
    if (exact != null) return exact;
    for (final entry in env.entries) {
      if (entry.key.toUpperCase() == name) return entry.value;
    }
    return null;
  }

  /// Search PATH for [name]. Falls back to `command -v` via a shell — skipped
  /// on Windows, which has no `/bin/sh`.
  static Future<String> locateTool(String name) async {
    final found = await which(name);
    if (found != null) return found;
    if (!Platform.isWindows) {
      final result = await Process.run('/bin/sh', ['-c', "command -v '$name'"]);
      final out = (result.stdout as String).trim();
      if (out.isNotEmpty) return out;
    }
    throw CliError("Could not find '$name' in PATH.");
  }

  /// Set mode 0755 on [path] via libc chmod (FFI) — no subprocess. posix is a
  /// no-op stub on non-POSIX hosts, so guard with isPosixSupported.
  static void makeExecutable(String path) {
    if (!Platform.isWindows && posix.isPosixSupported) {
      posix.chmod(path, '0755');
    }
  }

  /// Kill [process] together with everything it spawned.
  ///
  /// [Process.kill] signals one pid only. That is not enough for
  /// pip console-script wrappers on Windows (`foo.exe` runs the real
  /// interpreter as a child), where killing the wrapper leaves the child
  /// holding its listening socket.
  static Future<void> killTree(Process process) async {
    if (!Platform.isWindows) {
      process.kill();
      return;
    }
    try {
      await run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } on Object {
      // taskkill missing or the tree is already gone — fall through.
    }
    process.kill();
  }

  /// Wrap a bare IPv6 address in brackets for URL construction.
  static String bracketHost(String addr) =>
      addr.contains(':') ? '[$addr]' : addr;

  /// Strip IPv6 brackets so [Socket.connect] receives a raw host string.
  static String unbracketHost(String host) =>
      host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;

  /// Retry [attempt] every [interval] until it yields a non-null value or
  /// [timeout] elapses. Exceptions from [attempt] are swallowed and retried.
  /// Returns null when the deadline passes, so callers raise their own error.
  static Future<T?> pollUntil<T>({
    required Future<T?> Function() attempt,
    required Duration timeout,
    required Duration interval,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final result = await attempt();
        if (result != null) return result;
      } catch (_) {}
      await Future<void>.delayed(interval);
    }
    return null;
  }
}
