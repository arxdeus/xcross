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

/// Process lookup and child-environment overlay supplied by an embedding app.
@immutable
final class ProcessConfiguration {
  ProcessConfiguration({
    required Map<String, String> normalizedTools,
    required Map<String, List<String>> toolchainDirectories,
    required Map<String, String> effectiveChildEnvironment,
  }) : normalizedTools = Map.unmodifiable(normalizedTools),
       toolchainDirectories = Map.unmodifiable({
         for (final entry in toolchainDirectories.entries)
           entry.key: List<String>.unmodifiable(entry.value),
       }),
       effectiveChildEnvironment = Map.unmodifiable(effectiveChildEnvironment);

  final Map<String, String> normalizedTools;
  final Map<String, List<String>> toolchainDirectories;
  final Map<String, String> effectiveChildEnvironment;
}

/// Wrappers around `dart:io` [Process] with consistent UTF-8 decoding and
/// error reporting.
abstract final class ProcessRunner {
  static ProcessConfiguration? _configuration;

  /// Installs process inputs owned by the embedding application.
  ///
  /// This is opt-in; without a call to [configure], all behavior remains based
  /// on the host process environment. Operation-local environment entries take
  /// precedence over [effectiveChildEnvironment].
  static void configure({
    required Map<String, String> normalizedTools,
    required Map<String, String> effectiveChildEnvironment,
    Map<String, List<String>> toolchainDirectories = const {},
  }) {
    _configuration = ProcessConfiguration(
      normalizedTools: normalizedTools,
      toolchainDirectories: toolchainDirectories,
      effectiveChildEnvironment: effectiveChildEnvironment,
    );
  }

  /// Removes process configuration, primarily for isolation between tests.
  static void resetConfiguration() => _configuration = null;

  /// The installed process configuration, if any.
  static ProcessConfiguration? get configuration => _configuration;

  /// Base environment production callers should use when constructing a
  /// complete operation-local environment.
  ///
  /// Without configuration this is the host environment, preserving legacy
  /// behavior. Once configured it is the inherited environment with the
  /// embedding application's allowlisted overlay applied.
  static Map<String, String> get effectiveEnvironment =>
      _configuration?.effectiveChildEnvironment ?? Platform.environment;

  static Map<String, String>? _childEnvironment(
    Map<String, String>? operationEnvironment,
  ) {
    final configuration = _configuration;
    final configured = configuration?.effectiveChildEnvironment;
    if (configured == null) return operationEnvironment;
    if (operationEnvironment == null) return {...configured};

    return {...configured, ...operationEnvironment};
  }

  static bool get _inheritParentEnvironment => _configuration == null;

  static String _resolvedExecutable(String executable) {
    final configuration = _configuration;
    if (configuration == null || p.isAbsolute(executable)) return executable;
    final configured =
        configuration.normalizedTools[_normalizedToolName(executable)];
    if (configured != null) return configured;
    return _toolchainOverride(executable, configuration, Platform.isWindows) ??
        executable;
  }

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

  /// Starts [executable] with the configured child environment.
  ///
  /// This preserves the streaming [Process] API while applying the same
  /// configured environment overlay as [run].
  static Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => Process.start(
    _resolvedExecutable(executable),
    arguments,
    workingDirectory: workingDirectory,
    environment: _childEnvironment(environment),
    includeParentEnvironment: _inheritParentEnvironment,
    runInShell: runInShell,
    mode: mode,
  );

  /// Runs [executable] to completion, capturing stdout/stderr as UTF-8.
  static Future<CapturedProcess> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final result = await Process.run(
      _resolvedExecutable(executable),
      arguments,
      workingDirectory: workingDirectory,
      environment: _childEnvironment(environment),
      includeParentEnvironment: _inheritParentEnvironment,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
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

  /// Runs a build tool as a phase of the current [Step], throwing [CliError]
  /// on a non-zero exit.
  ///
  /// The output policy every compiler, linker, and build driver should share:
  ///
  /// * `--verbose` hands the tool this terminal, so its own progress rendering
  ///   and any crash message survive intact.
  /// * Otherwise output collapses into the running phase's grey tail, and is
  ///   quoted in full only if the tool fails.
  ///
  /// Never forwards stdin: `compose run --watch` reads `r`/`q` from the same
  /// terminal, and a build child holding stdin swallows those keys.
  static Future<void> runTool(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? label,
  }) => runChecked(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    inheritStdio: Log.isVerbose,
    tail: Log.isVerbose ? null : Log.activeStep,
    forwardStdin: false,
    label: label ?? p.basename(executable),
  );

  static Future<void> _runInheritingStdio(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      _resolvedExecutable(executable),
      arguments,
      workingDirectory: workingDirectory,
      environment: _childEnvironment(environment),
      includeParentEnvironment: _inheritParentEnvironment,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code != 0) {
      throw CliError(
        _failureMessage(executable, arguments, code, captured: false),
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
      _failureMessage(executable, arguments, result.exitCode, output: output),
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
      _resolvedExecutable(executable),
      arguments,
      workingDirectory: workingDirectory,
      environment: _childEnvironment(environment),
      includeParentEnvironment: _inheritParentEnvironment,
    );

    final captured = StringBuffer();
    void sink(String chunk) {
      captured.write(chunk);
      tail.log(chunk);
    }

    final drained = Future.wait([
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(sink),
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(sink),
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
          _failureMessage(executable, arguments, code, output: '$captured'),
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

  /// NTSTATUS values Windows hands back as a process exit code when the tool
  /// died instead of exiting on its own terms.
  static const _windowsStatuses = <int, String>{
    0xC0000005: 'STATUS_ACCESS_VIOLATION, a bad pointer dereference',
    0xC000001D: 'STATUS_ILLEGAL_INSTRUCTION',
    0xC000007B: 'STATUS_INVALID_IMAGE_FORMAT, a wrong-architecture binary',
    0xC00000FD: 'STATUS_STACK_OVERFLOW',
    0xC0000135: 'STATUS_DLL_NOT_FOUND, a DLL it needs is not on PATH',
    0xC0000139: 'STATUS_ENTRYPOINT_NOT_FOUND, a DLL on PATH is the wrong build',
    0xC0000142: 'STATUS_DLL_INIT_FAILED',
    0xC0000374: 'STATUS_HEAP_CORRUPTION',
    0xC0000409:
        'STATUS_STACK_BUFFER_OVERRUN, which is how Windows reports abort() — '
        'normally a failed assertion or a fatal error inside the tool',
  };

  /// Anything at or above this is an NTSTATUS error, not a chosen exit status.
  /// No POSIX status reaches it either — those are 0..255, or a small negative
  /// number for a signal — so the two conventions never collide.
  static const _ntStatusError = 0xC0000000;

  /// dart:io reports a Windows exit code either as the raw DWORD or
  /// sign-extended into a negative int, so both forms have to normalize.
  static int _asNtStatus(int exitCode) =>
      exitCode < 0 ? exitCode + 0x1_0000_0000 : exitCode;

  /// A sign-extended NTSTATUS lands far below the small negatives dart:io
  /// reports for a POSIX signal, so magnitude tells the two conventions apart.
  static bool _isNtStatus(int exitCode) => exitCode >= 0
      ? exitCode >= _ntStatusError
      : exitCode >= _ntStatusError - 0x1_0000_0000 && exitCode <= -256;

  /// Whether [exitCode] means the process died rather than exiting with a
  /// status of its own — an NTSTATUS on Windows, a signal on POSIX.
  static bool crashed(int exitCode) =>
      _isNtStatus(exitCode) || (exitCode < 0 && exitCode > -256);

  /// What an abnormal [exitCode] means, or null when the number says nothing
  /// beyond "non-zero".
  static String? describeExitCode(int exitCode) {
    if (!_isNtStatus(exitCode)) {
      return exitCode < 0 ? 'killed by signal ${-exitCode}' : null;
    }
    final status = _asNtStatus(exitCode);
    final hex = '0x${status.toRadixString(16).toUpperCase()}';
    final known = _windowsStatuses[status];
    if (known != null) return '$hex $known';
    return '$hex, an NTSTATUS crash code: the tool died instead of exiting';
  }

  /// A tool that fast-fails leaves nothing behind when its output was piped:
  /// Windows buffers a redirected stderr and `abort()` never flushes it.
  static String _failureMessage(
    String executable,
    List<String> arguments,
    int exitCode, {
    String output = '',
    bool captured = true,
  }) {
    final detail = describeExitCode(exitCode);
    final message = StringBuffer('command failed ($exitCode')
      ..write(detail == null ? '' : ': $detail')
      ..write('): ${commandLine(executable, arguments)}');
    if (output.trim().isNotEmpty) {
      message.write('\n$output');
    } else if (captured && crashed(exitCode)) {
      message.write(
        '\nIt wrote nothing before dying. Re-run with --verbose: that hands '
        'the tool this terminal instead of a pipe, which is the only way its '
        'crash message survives.',
      );
    }
    return message.toString();
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
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) async => (await whichAll(
    name,
    environment: environment,
    windows: windows,
    accept: accept,
    extraDirectories: extraDirectories,
    useConfiguration: useConfiguration,
  )).firstOrNull;

  /// Every match for [name] on PATH, in PATH order, then in
  /// [extraDirectories] — install locations worth trying when a toolchain
  /// never registered itself on PATH.
  ///
  /// Use this when the first match is not necessarily the right one and the
  /// choice needs the whole candidate list.
  static Future<List<String>> whichAll(
    String name, {
    Map<String, String>? environment,
    bool? windows,
    bool Function(String path)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) async {
    final configured = useConfiguration ? _configuration : null;
    final env = configured == null
        ? environment ?? effectiveEnvironment
        : {...effectiveEnvironment, ...?environment};
    final onWindows = windows ?? Platform.isWindows;
    final names = _candidateNames(
      name,
      onWindows ? _pathExtensions(env) : const [],
    );
    final override = _toolOverride(
      configured?.normalizedTools,
      names,
      caseInsensitive: onWindows,
    );
    if (override != null && (accept == null || accept(override))) {
      return [override];
    }
    final toolchain = configured == null
        ? null
        : _toolchainOverride(name, configured, onWindows, accept: accept);

    final found = <String>[if (toolchain != null) toolchain];
    final seen = <String>{};
    final searchPath = _environmentValue(env, 'PATH') ?? '';
    final directories = [
      ...searchPath.split(onWindows ? ';' : ':'),
      ...extraDirectories,
    ];
    if (toolchain != null) {
      seen.add(
        Platform.isWindows || onWindows ? toolchain.toLowerCase() : toolchain,
      );
    }
    for (final dir in directories) {
      if (dir.isEmpty) continue;
      for (final candidateName in names) {
        final candidate = p.join(dir, candidateName);
        // A directory can be both on PATH and a known install location.
        final absoluteCandidate = p.normalize(File(candidate).absolute.path);
        final candidateKey = Platform.isWindows || onWindows
            ? absoluteCandidate.toLowerCase()
            : absoluteCandidate;
        if (!seen.add(candidateKey)) {
          continue;
        }

        if (File(candidate).existsSync() &&
            (accept == null || accept(candidate))) {
          found.add(candidate);
        }
      }
    }
    return found;
  }

  static String? _toolchainOverride(
    String name,
    ProcessConfiguration configuration,
    bool windows, {
    bool Function(String path)? accept,
  }) {
    final normalized = _normalizedToolName(name);
    String? basename;
    List<String>? directories;
    if (const {
      'swift',
      'swiftc',
      'swift-package',
      'swift-build',
      'swift-frontend',
    }.contains(normalized)) {
      basename = normalized;
      directories = configuration.toolchainDirectories['swift'];
    } else if (normalized == 'cc') {
      basename = 'clang';
      directories = configuration.toolchainDirectories['llvm'];
    } else if (normalized == 'clang' ||
        normalized == 'clang++' ||
        normalized == 'ld64.lld' ||
        normalized == 'dsymutil' ||
        normalized.startsWith('llvm-')) {
      basename = normalized;
      directories = configuration.toolchainDirectories['llvm'];
    }
    if (basename == null || directories == null) return null;
    final candidates = _candidateNames(
      basename,
      windows
          ? _pathExtensions(configuration.effectiveChildEnvironment)
          : const [],
    );
    for (final directory in directories) {
      for (final candidate in candidates) {
        final path = p.join(directory, candidate);
        if (File(path).existsSync() && (accept == null || accept(path))) {
          return path;
        }
      }
    }
    return null;
  }

  static String? _toolOverride(
    Map<String, String>? tools,
    List<String> candidateNames, {
    required bool caseInsensitive,
  }) {
    if (tools == null) return null;
    for (final candidate in candidateNames) {
      final normalized = _normalizedToolName(candidate);
      final exact = tools[normalized] ?? tools[candidate];
      if (exact != null) return exact;
      if (caseInsensitive) {
        for (final entry in tools.entries) {
          if (_normalizedToolName(entry.key) == normalized) return entry.value;
        }
      }
    }
    return null;
  }

  static String _normalizedToolName(String name) {
    final normalized = name.trim().toLowerCase();
    for (final extension in const ['.exe', '.cmd', '.bat', '.com']) {
      if (normalized.endsWith(extension)) {
        return normalized.substring(0, normalized.length - extension.length);
      }
    }
    return normalized;
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
  static Future<String> locateTool(
    String name, {
    Iterable<String> extraDirectories = const [],
  }) async {
    final found = await which(name, extraDirectories: extraDirectories);
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
      final taskkill = await locateTool('taskkill');
      await run(taskkill, ['/PID', '${process.pid}', '/T', '/F']);
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
