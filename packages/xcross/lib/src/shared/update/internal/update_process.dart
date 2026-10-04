import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/errors/errors.dart';

Future<ProcessResult> runUpdateProcess(
  ProcessRunner runner,
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  try {
    final process = await runner.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();

    Future<void> collect(Stream<List<int>> stream, StringBuffer buffer) async {
      await for (final chunk in stream.transform(systemEncoding.decoder)) {
        buffer.write(chunk);
        runner.log.activeStep?.log(chunk);
      }
    }

    await Future.wait([
      collect(process.stdout, stdoutBuffer),
      collect(process.stderr, stderrBuffer),
    ]);
    final code = await process.exitCode;
    return ProcessResult(
      process.pid,
      code,
      stdoutBuffer.toString(),
      stderrBuffer.toString(),
    );
  } on ProcessException {
    throw XcrossError(
      'failed to start required executable "$executable"; install it and '
      'ensure it is available on PATH',
    );
  }
}
