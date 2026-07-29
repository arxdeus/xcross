import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

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
  /// When [inheritStdio] is true the child shares this process's stdio via
  /// [ProcessStartMode.inheritStdio] (needed for interactive prompts like
  /// `xtool install` certificate revocation). Otherwise output is captured
  /// and the stderr is included in the thrown error.
  static Future<void> runChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool inheritStdio = false,
    String? label,
  }) async {
    final prefix = label ?? _labelForExecutable(executable);
    logStatus('[$prefix] running: ${commandLine(executable, arguments)}');

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

  static final _shellSpecialCharsPattern = RegExp(r'''[\s'"\\$`]''');

  static String _labelForExecutable(String executable) {
    final normalized = executable.replaceAll(r'\', '/');
    final base = normalized.split('/').last;
    if (base.isEmpty) return executable;
    return base;
  }

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
String unbracketHost(String host) =>
    host.startsWith('[') && host.endsWith(']')
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
