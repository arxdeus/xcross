import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/src/shared/errors/errors.dart';
import 'package:cli_kit/src/shared/logging/logging.dart';
import 'package:cli_kit/src/shared/platform/platform_host.dart';
import 'package:cli_kit/src/shared/process/process_helpers.dart';
import 'package:cli_kit/src/shared/process/process_models.dart';
import 'package:cli_kit/src/shared/process/tool_lookup.dart';

final class ProcessExecutor<T extends PlatformHostInterface> {
  ProcessExecutor(this.host, {required this.tools, required this.log}) {
    if (!identical(host, tools.host)) {
      throw ArgumentError('Process executor and lookup must use the same host');
    }
  }
  final T host;
  final ProcessToolLookupInterface<T> tools;
  final Log log;
  Map<String, String> get effectiveEnvironment => tools.effectiveEnvironment;
  ProcessConfiguration? get configuration => tools.configuration;
  Map<String, String> _childEnvironment(
    Map<String, String>? operationEnvironment,
  ) => host.environment.overlay(
    effectiveEnvironment,
    operationEnvironment ?? const {},
  );

  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => host.processes.start(
    tools.resolveExecutable(executable),
    arguments,
    workingDirectory: host.paths.ioPath(
      workingDirectory ?? host.paths.context.current,
    ),
    environment: _childEnvironment(environment),
    includeParentEnvironment: false,
    runInShell: runInShell,
    mode: mode,
  );

  Future<CapturedProcess> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    if (timeout != null) {
      return _runWithTimeout(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        timeout: timeout,
      );
    }
    final process = await start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final output = Future.wait([
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join(),
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join(),
    ]);
    try {
      await process.stdin.close();
    } on Object catch (error) {
      log.logTrace('Could not close child stdin: $error');
    }
    final code = await process.exitCode;
    final captured = await output;
    return CapturedProcess(code, captured[0], captured[1]);
  }

  Future<CapturedProcess> _runWithTimeout(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final out = StringBuffer();
    final err = StringBuffer();
    final drained = Future.wait([
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(out.write),
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(err.write),
    ]);
    try {
      await process.stdin.close();
    } on Object catch (_) {}

    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      unawaited(killTree(process));
    });
    try {
      final code = await process.exitCode;
      await drained.catchError((Object _) => <void>[]);
      return CapturedProcess(
        code,
        out.toString(),
        err.toString(),
        timedOut: timedOut,
      );
    } finally {
      timer.cancel();
    }
  }

  Future<int> awaitExitWithin(
    Process process,
    Duration? timeout,
    String executable,
    List<String> arguments,
  ) async {
    if (timeout == null) return process.exitCode;
    try {
      return await process.exitCode.timeout(timeout);
    } on TimeoutException {
      await killTree(process);
      throw CliError(
        'command timed out after ${timeout.inSeconds}s and was killed: '
        '${ProcessHelpers.commandLine(executable, arguments)}',
      );
    }
  }

  Future<void> killTree(Process process) => host.processes.killTree(
    process,
    environment: effectiveEnvironment,
    executableOverrides: configuration?.normalizedTools ?? const {},
  );
}
