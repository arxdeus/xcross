import 'dart:io';

import 'package:cli_kit/host/shared/io_tui_terminal.dart';
import 'package:xcross/src/composition/cli/runner.dart';
import 'package:xcross/src/composition/native_runtime.dart';

Future<void> main(List<String> args) async {
  var code = 0;
  try {
    final context = createNativeXcrossContext();
    final aliasCode = await context.toolAliases.run(
      args,
      executablePath: context.executable,
    );
    if (aliasCode != null) exit(aliasCode);
    code = await context.runApplication(
      args,
      configTerminal: IoTuiTerminal(input: stdin, output: stdout),
    );
  } on Object catch (error, stackTrace) {
    stderr.writeln(XcrossCli.formatFailure(error, stackTrace));
    code = 1;
  }
  await _exit(code);
}

/// Terminate explicitly once the command is done.
///
/// Setting [exitCode] alone waits for the event loop to drain, and any
/// lingering stdin subscription, socket, HTTP client, timer, or child process
/// (after `q`, an auth failure, or any other error path) keeps the CLI
/// hanging forever. Flush first so the final lines are not lost.
Future<Never> _exit(int code) async {
  try {
    await Future.wait([stdout.flush(), stderr.flush()])
        .timeout(const Duration(seconds: 2));
  } on Object {
    // Best effort; a wedged stdout must not block termination.
  }
  exit(code);
}
