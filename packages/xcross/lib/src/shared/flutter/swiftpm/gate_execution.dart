import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';

@internal
abstract interface class SwiftPmGateProcess {
  PlatformHostInterface get host;
  Future<ProcessResult> runGateProcess(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  });
}

@internal
final class SwiftPmGateLiveProcessException implements Exception {
  SwiftPmGateLiveProcessException({
    required this.executable,
    required this.processId,
    required this.cause,
    required this.cleanupError,
  });
  final String executable;
  final int processId;
  final Object cause;
  final Object cleanupError;
  @override
  String toString() =>
      'Gate process $processId ($executable) completion is unconfirmed: '
      '$cause; cleanup: $cleanupError';
}

@internal
final class SwiftPmGateExecution<T extends PlatformHostInterface>
    implements SwiftPmGateProcess {
  SwiftPmGateExecution({required this.runner});
  final ProcessRunner<T> runner;
  @override
  T get host => runner.host;
  @override
  Future<ProcessResult> runGateProcess(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  }) async {
    final process = await runner.start(
      executable,
      arguments,
      environment: environment,
    );
    final output = StringBuffer();
    final error = StringBuffer();
    final outputDone = Completer<void>();
    final errorDone = Completer<void>();
    outputDone.future.ignore();
    errorDone.future.ignore();
    StreamSubscription<String>? outputSubscription;
    StreamSubscription<String>? errorSubscription;
    Future<void>? completion;
    int? exitCode;
    try {
      outputSubscription = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            output.write,
            onError: (Object error, StackTrace stack) {
              if (!outputDone.isCompleted) {
                outputDone.completeError(error, stack);
              }
            },
            onDone: () {
              if (!outputDone.isCompleted) outputDone.complete();
            },
          );
      errorSubscription = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            error.write,
            onError: (Object error, StackTrace stack) {
              if (!errorDone.isCompleted) errorDone.completeError(error, stack);
            },
            onDone: () {
              if (!errorDone.isCompleted) errorDone.complete();
            },
          );
      completion = Future.wait<void>([
        process.exitCode.then<void>((value) {
          exitCode = value;
        }),
        outputDone.future,
        errorDone.future,
      ], eagerError: true);
      await completion.timeout(timeout);
      return ProcessResult(process.pid, exitCode!, '$output', '$error');
    } on Object catch (cause) {
      Object? cleanupError;
      try {
        await runner.killTree(process).timeout(const Duration(seconds: 2));
      } on Object catch (error) {
        cleanupError = error;
      }
      if (completion == null) {
        cleanupError ??= StateError(
          'Gate output/exit completion is unavailable',
        );
      } else {
        try {
          await completion.timeout(const Duration(seconds: 2));
        } on Object catch (error) {
          cleanupError ??= error;
        }
      }
      if (cleanupError != null) {
        throw SwiftPmGateLiveProcessException(
          executable: executable,
          processId: process.pid,
          cause: cause,
          cleanupError: cleanupError,
        );
      }
      rethrow;
    } finally {
      await Future<void>.sync(
        () => outputSubscription?.cancel(),
      ).timeout(const Duration(seconds: 2)).catchError((Object _) {});
      await Future<void>.sync(
        () => errorSubscription?.cancel(),
      ).timeout(const Duration(seconds: 2)).catchError((Object _) {});
    }
  }
}
