import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';

abstract interface class SwiftPmGateProcess {
  PlatformHostInterface get host;
  Future<ProcessResult> runGateProcess(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  });
}

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
    try {
      final output = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final error = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(process.pid, exitCode, await output, await error);
    } on TimeoutException {
      await runner.killTree(process);
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
      rethrow;
    }
  }
}
