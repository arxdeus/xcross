import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/errors.dart';

Future<ProcessResult> runUpdateProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  try {
    final lowerExecutable = executable.toLowerCase();
    final runInShell =
        Platform.isWindows &&
        (lowerExecutable.endsWith('.bat') || lowerExecutable.endsWith('.cmd'));
    // cmd.exe expands %NAME% in batch arguments. Escape each percent so an
    // encoded ref such as feature%2Fa%2Cb%3Dc reaches Dart unchanged.
    final processArguments = runInShell
        ? arguments.map((argument) => argument.replaceAll('%', '^%')).toList()
        : arguments;
    final process = await ProcessRunner.start(
      executable,
      processArguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: runInShell,
    );
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();

    Future<void> collect(Stream<List<int>> stream, StringBuffer buffer) async {
      await for (final chunk in stream.transform(systemEncoding.decoder)) {
        buffer.write(chunk);
        Log.activeStep?.log(chunk);
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
