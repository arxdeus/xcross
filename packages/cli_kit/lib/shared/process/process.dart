import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process_executor.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:cli_kit/shared/process/tool_lookup.dart';
import 'package:cli_kit/src/shared/process/process_helpers.dart';

final class ProcessRunner<T extends PlatformHostInterface> {
  ProcessRunner(
    this.host, {
    required this.log,
    required Stream<List<int>> stdinStream,
    required IOSink stdoutSink,
    required IOSink stderrSink,
    this.configuration,
    ProcessToolLookupInterface<T>? toolLookup,
    ProcessExecutor<T>? executor,
  }) : _stdinStream = stdinStream,
       _stdout = stdoutSink,
       _stderr = stderrSink {
    this.toolLookup =
        toolLookup ??
        executor?.tools ??
        ProcessToolLookup(host, configuration: configuration);
    if (!identical(this.toolLookup.host, host) ||
        !identical(this.toolLookup.configuration, configuration)) {
      throw ArgumentError(
        'Process lookup must use the runner host and configuration',
      );
    }
    if (executor != null &&
        (!identical(executor.host, host) ||
            !identical(executor.tools, this.toolLookup) ||
            !identical(executor.log, log))) {
      throw ArgumentError(
        'Process executor must use the runner host, lookup and log',
      );
    }
    this.executor =
        executor ?? ProcessExecutor(host, tools: this.toolLookup, log: log);
  }
  final T host;
  final Log log;
  final ProcessConfiguration? configuration;
  late final ProcessToolLookupInterface<T> toolLookup;
  late final ProcessExecutor<T> executor;
  final Stream<List<int>> _stdinStream;
  final IOSink _stdout;
  final IOSink _stderr;
  Stream<List<int>>? _sharedStdin;
  Map<String, String> get effectiveEnvironment =>
      toolLookup.effectiveEnvironment;
  Stream<List<int>> get sharedStdin =>
      _sharedStdin ??= pausingBroadcast(_stdinStream);
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => executor.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: runInShell,
    mode: mode,
  );
  Future<CapturedProcess> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) => executor.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    timeout: timeout,
  );
  Future<void> killTree(Process process) => executor.killTree(process);
  String hostExecutableName(String name, {String extension = '.exe'}) =>
      toolLookup.hostExecutableName(name, extension: extension);
  String? environmentValue(Map<String, String> environment, String name) =>
      toolLookup.environmentValue(environment, name);
  bool isSwiftlyProxy(String path) => toolLookup.isSwiftlyProxy(path);
  Future<String?> which(
    String name, {
    Map<String, String>? environment,
    bool Function(String)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) => toolLookup.which(
    name,
    environment: environment,
    accept: accept,
    extraDirectories: extraDirectories,
    useConfiguration: useConfiguration,
  );
  Future<List<String>> whichAll(
    String name, {
    Map<String, String>? environment,
    bool Function(String)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) => toolLookup.whichAll(
    name,
    environment: environment,
    accept: accept,
    extraDirectories: extraDirectories,
    useConfiguration: useConfiguration,
  );
  Future<String> locateTool(
    String name, {
    Iterable<String> extraDirectories = const [],
  }) => toolLookup.locateTool(name, extraDirectories: extraDirectories);
  void makeExecutable(String path) => host.fileSystem.makeExecutable(path);
  static Stream<U> pausingBroadcast<U>(Stream<U> source) =>
      ProcessHelpers.pausingBroadcast(source);
  static String commandLine(String executable, List<String> arguments) =>
      ProcessHelpers.commandLine(executable, arguments);
  static bool crashed(int code) => ProcessHelpers.crashed(code);
  static String? describeExitCode(int code) =>
      ProcessHelpers.describeExitCode(code);
  static String bracketHost(String address) =>
      ProcessHelpers.bracketHost(address);
  static String unbracketHost(String address) =>
      ProcessHelpers.unbracketHost(address);
  static Future<U?> pollUntil<U>({
    required Future<U?> Function() attempt,
    required Duration timeout,
    required Duration interval,
    bool Function()? cancelled,
  }) => ProcessHelpers.pollUntil(
    attempt: attempt,
    timeout: timeout,
    interval: interval,
    cancelled: cancelled,
  );
  Future<void> runChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool inheritStdio = false,
    bool captureAndEcho = false,
    String? label,
    Step? tail,
    bool forwardStdin = true,
    Duration? timeout,
  }) {
    log.logTrace(
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
        timeout: timeout,
      );
    }
    if (captureAndEcho) {
      return _runCapturedStreaming(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        timeout: timeout,
      );
    }
    if (inheritStdio) {
      return _runInheritingStdio(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        timeout: timeout,
      );
    }
    return _runCaptured(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
  }

  Future<void> runTool(
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
    inheritStdio: log.isVerbose,
    tail: log.isVerbose ? null : log.activeStep,
    forwardStdin: false,
    label: label ?? host.paths.context.basename(executable),
  );

  Future<void> _runInheritingStdio(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final process = await start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await executor.awaitExitWithin(
      process,
      timeout,
      executable,
      arguments,
    );
    if (code != 0) {
      throw CliError(
        ProcessHelpers.failureMessage(
          executable,
          arguments,
          code,
          captured: false,
        ),
      );
    }
  }

  Future<void> _runCaptured(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final result = await run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
    if (result.exitCode == 0) return;
    if (result.timedOut) {
      throw CliError(
        'command timed out after ${timeout!.inSeconds}s and was killed: '
        '${commandLine(executable, arguments)}',
      );
    }
    final output = [
      result.stdout,
      result.stderr,
    ].where((s) => s.trim().isNotEmpty).join('\n');
    throw CliError(
      ProcessHelpers.failureMessage(
        executable,
        arguments,
        result.exitCode,
        output: output,
      ),
    );
  }

  Future<void> _runCapturedStreaming(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final process = await start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final captured = StringBuffer();
    final drained = Future.wait([
      _captureAndEchoStream(process.stdout, captured, _stdout),
      _captureAndEchoStream(process.stderr, captured, _stderr),
    ]);
    try {
      await process.stdin.close();
    } on Object catch (_) {}
    final code = await executor.awaitExitWithin(
      process,
      timeout,
      executable,
      arguments,
    );
    await drained;
    if (code != 0) {
      throw CliError(
        ProcessHelpers.failureMessage(
          executable,
          arguments,
          code,
          output: '$captured',
        ),
      );
    }
  }

  Future<void> _captureAndEchoStream(
    Stream<List<int>> source,
    StringBuffer captured,
    IOSink echo,
  ) => source.transform(const Utf8Decoder(allowMalformed: true)).forEach((
    chunk,
  ) {
    captured.write(chunk);
    echo.write(chunk);
  });

  Future<void> _runWithTail(
    String executable,
    List<String> arguments, {
    required Step tail,
    String? workingDirectory,
    Map<String, String>? environment,
    bool forwardStdin = true,
    Duration? timeout,
  }) async {
    final process = await start(
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
      final code = await executor.awaitExitWithin(
        process,
        timeout,
        executable,
        arguments,
      );
      await input?.cancel();
      input = null;
      await drained;
      if (code != 0) {
        throw CliError(
          ProcessHelpers.failureMessage(
            executable,
            arguments,
            code,
            output: '$captured',
          ),
        );
      }
    } finally {
      await input?.cancel();
      unawaited(process.stdin.close().catchError((Object _) {}));
    }
  }

  StreamSubscription<List<int>>? _forwardStdinTo(
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
      log.logTrace('stdin not forwarded to $label: $e');
      return null;
    }
  }
}
