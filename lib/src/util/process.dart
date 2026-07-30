import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Every stdin reader in the process must go through this one broadcast.
///
/// Cancelling a subscription to [stdin] closes the underlying fd for good: a
/// later `stdin.listen` then fires `onDone` immediately instead of delivering
/// keys, which silently killed the hot-reload keypress loop after an install.
/// `onCancel`/`onListen` pause and resume the source instead of tearing it
/// down, so bytes typed between readers stay queued in the tty.
Stream<List<int>> get sharedStdin => _sharedStdin ??= pausingBroadcast(stdin);
Stream<List<int>>? _sharedStdin;

/// A broadcast view of [source] that pauses — never cancels — the source
/// subscription when its last listener goes away, so a later listener still
/// gets events. Split out from [sharedStdin] so it is testable without a tty.
Stream<T> pausingBroadcast<T>(Stream<T> source) => source.asBroadcastStream(
      onListen: (sub) {
        if (sub.isPaused) sub.resume();
      },
      onCancel: (sub) => sub.pause(),
    );

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

  /// Run [executable], throwing [XcrossError] on a non-zero exit code.
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
  }) async {
    final prefix = label ?? executable;
    logTrace('[$prefix] running: ${commandLine(executable, arguments)}');

    if (tail != null) {
      return _runWithTail(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        tail: tail,
      );
    }

    if (inheritStdio) {
      // Must use inheritStdio (not piped stdout/stderr): xtool writes
      // confirmation prompts without a trailing newline and reads stdin.
      // Piping + LineSplitter hid the prompt and left stdin disconnected,
      // so install hung at "certificates must be revoked".
      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        mode: ProcessStartMode.inheritStdio,
      );
      final code = await process.exitCode;
      if (code != 0) {
        throw XcrossError(
            'command failed ($code): ${commandLine(executable, arguments)}');
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
      throw XcrossError(
        'command failed (${result.exitCode}): '
        '${commandLine(executable, arguments)}\n${result.stderr}',
      );
    }
  }

  /// Stream a child's merged output into [tail] while forwarding our stdin to
  /// it. The stdin forwarding is what makes this safe for `xtool install`:
  /// piping alone previously hid its "certificates must be revoked" prompt AND
  /// left the child's stdin disconnected, so the install hung forever.
  static Future<void> _runWithTail(
    String executable,
    List<String> arguments, {
    required Step tail,
    String? workingDirectory,
    Map<String, String>? environment,
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
    try {
      input = sharedStdin.listen(
        (bytes) {
          try {
            process.stdin.add(bytes);
          } on Object catch (_) {
            // Child already gone; nothing left to feed.
          }
        },
        onError: (Object _) {},
      );
    } on Object catch (e) {
      // Unavailable stdin is not fatal: the child simply gets no input,
      // exactly as before this streaming path existed.
      logTrace('stdin not forwarded to $executable: $e');
    }

    try {
      final code = await process.exitCode;
      // Stop forwarding the moment the child is gone, before its pipe errors.
      await input?.cancel();
      input = null;
      await drained;
      if (code != 0) {
        throw XcrossError(
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
}

/// Absolute path to [name] on PATH, or null if not found.
Future<String?> which(String name) async {
  final pathEnv = Platform.environment['PATH'] ?? '';
  for (final dir in pathEnv.split(':')) {
    if (dir.isEmpty) continue;
    final file = File('$dir/$name');
    if (file.existsSync()) return file.path;
  }
  return null;
}

/// Search PATH for [name]. Falls back to `command -v` via a shell.
Future<String> locateTool(String name) async {
  final pathEnv = Platform.environment['PATH'] ?? '';
  for (final dir in pathEnv.split(':')) {
    final candidate = p.join(dir, name);
    final candidateExists = File(candidate).existsSync();
    if (candidateExists) return candidate;
  }
  final result = await Process.run('/bin/sh', ['-c', "command -v '$name'"]);
  final out = (result.stdout as String).trim();
  if (out.isNotEmpty) return out;
  throw XcrossError("Could not find '$name' in PATH.");
}

/// Set mode 0755 on [path] via libc chmod (FFI) — no subprocess. posix is a
/// no-op stub on non-POSIX hosts, so guard with isPosixSupported.
void makeExecutable(String path) {
  if (posix.isPosixSupported) posix.chmod(path, '0755');
}

/// Wrap a bare IPv6 address in brackets for URL construction.
String bracketHost(String addr) => addr.contains(':') ? '[$addr]' : addr;

/// Strip IPv6 brackets so [Socket.connect] receives a raw host string.
String unbracketHost(String host) => host.startsWith('[') && host.endsWith(']')
    ? host.substring(1, host.length - 1)
    : host;

/// Retry [attempt] every [interval] until it yields a non-null value or
/// [timeout] elapses. Exceptions from [attempt] are swallowed and retried.
/// Returns null when the deadline passes, so callers raise their own error.
Future<T?> pollUntil<T>({
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
