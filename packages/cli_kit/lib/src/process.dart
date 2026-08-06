import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/src/errors.dart';
import 'package:cli_kit/src/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:pure/pure.dart';

/// Captured result of a finished subprocess.
@immutable
final class CapturedProcess {
  const CapturedProcess(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Wrappers around `dart:io` [Process] with consistent UTF-8 decoding and
/// error reporting.
abstract final class ProcessRunner {
  /// The single broadcast every stdin reader in the process must share:
  /// cancelling a direct `stdin` subscription closes the fd for good, while
  /// this view only pauses the source between listeners.
  static Stream<List<int>> get sharedStdin =>
      _sharedStdin ??= pausingBroadcast(stdin);
  static Stream<List<int>>? _sharedStdin;

  /// A broadcast view of [source] that pauses — never cancels — the source
  /// subscription when its last listener goes away.
  static Stream<T> pausingBroadcast<T>(Stream<T> source) =>
      source.asBroadcastStream(
        onListen: (sub) => callIf(sub.isPaused, sub.resume),
        onCancel: (sub) => sub.pause(),
      );

  /// Runs [executable] to completion, capturing stdout/stderr as UTF-8.
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

  /// Runs [executable], throwing [CliError] on a non-zero exit code.
  ///
  /// With [tail], output streams into that step's tail and stdin is forwarded
  /// unless [forwardStdin] is false. With [inheritStdio], the child shares
  /// this process's stdio. Otherwise output is captured into the error.
  static Future<void> runChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool inheritStdio = false,
    String? label,
    Step? tail,
    bool forwardStdin = true,
  }) {
    Log.logTrace(
      '[${label ?? executable}] running: '
      '${commandLine(executable, arguments)}',
    );

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
      return _runInheritingStdio(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    }
    return _runCaptured(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  static Future<void> _runInheritingStdio(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
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
  }

  static Future<void> _runCaptured(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final result = await run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    if (result.exitCode == 0) return;
    final output = [
      result.stdout,
      result.stderr,
    ].where((s) => s.trim().isNotEmpty).join('\n');
    throw CliError(
      'command failed (${result.exitCode}): '
      '${commandLine(executable, arguments)}\n$output',
    );
  }

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

    final captured = StringBuffer();
    void sink(String chunk) {
      captured.write(chunk);
      tail.log(chunk);
    }

    final drained = Future.wait([
      process.stdout.transform(utf8.decoder).forEach(sink),
      process.stderr.transform(utf8.decoder).forEach(sink),
    ]);

    unawaited(process.stdin.done.catchError((Object _) {}));

    StreamSubscription<List<int>>? input;
    if (forwardStdin) {
      input = _forwardStdinTo(process, label: executable);
    } else {
      try {
        await process.stdin.close();
      } on Object catch (_) {}
    }

    try {
      final code = await process.exitCode;
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

  static StreamSubscription<List<int>>? _forwardStdinTo(
    Process process, {
    required String label,
  }) {
    try {
      return sharedStdin.listen((bytes) {
        try {
          process.stdin.add(bytes);
        } on Object catch (_) {}
      }, onError: (Object _) {});
    } on Object catch (e) {
      Log.logTrace('stdin not forwarded to $label: $e');
      return null;
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

  /// Whether [path] is one of swiftly's proxy shims that re-exec the matching
  /// tool from the active Swift toolchain.
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
  /// Windows lookup follows PATHEXT. [accept] rejects candidates that exist
  /// but are unusable, so the search continues down PATH.
  static Future<String?> which(
    String name, {
    Map<String, String>? environment,
    bool? windows,
    bool Function(String path)? accept,
  }) async {
    final env = environment ?? Platform.environment;
    final onWindows = windows ?? Platform.isWindows;
    final names = _candidateNames(
      name,
      onWindows ? _pathExtensions(env) : const [],
    );

    final searchPath = _environmentValue(env, 'PATH') ?? '';
    for (final dir in searchPath.split(onWindows ? ';' : ':')) {
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

  static List<String> _pathExtensions(Map<String, String> env) =>
      (_environmentValue(env, 'PATHEXT') ?? '.COM;.EXE;.BAT;.CMD')
          .split(';')
          .where((extension) => extension.isNotEmpty)
          .map(
            (extension) =>
                extension.startsWith('.') ? extension : '.$extension',
          )
          .toList();

  static List<String> _candidateNames(String name, List<String> extensions) {
    final lower = name.toLowerCase();
    if (extensions.any((e) => lower.endsWith(e.toLowerCase()))) return [name];
    return [name, for (final extension in extensions) '$name$extension'];
  }

  static String? _environmentValue(Map<String, String> env, String name) {
    final exact = env[name];
    if (exact != null) return exact;
    for (final entry in env.entries) {
      if (entry.key.toUpperCase() == name) return entry.value;
    }
    return null;
  }

  /// Searches PATH for [name], falling back to `command -v` on POSIX.
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

  /// Sets mode 0755 on [path] via libc chmod where POSIX applies.
  static void makeExecutable(String path) {
    if (!Platform.isWindows && posix.isPosixSupported) {
      posix.chmod(path, '0755');
    }
  }

  /// Kills [process] together with everything it spawned.
  static Future<void> killTree(Process process) async {
    if (!Platform.isWindows) {
      process.kill();
      return;
    }
    try {
      await run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } on Object {
      Log.logTrace('taskkill failed for pid ${process.pid}');
    }
    process.kill();
  }

  /// Wraps a bare IPv6 address in brackets for URL construction.
  static String bracketHost(String addr) =>
      addr.contains(':') ? '[$addr]' : addr;

  /// Strips IPv6 brackets so [Socket.connect] receives a raw host string.
  static String unbracketHost(String host) =>
      host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;

  /// Retries [attempt] every [interval] until it yields a non-null value or
  /// [timeout] elapses; exceptions are swallowed and retried.
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
