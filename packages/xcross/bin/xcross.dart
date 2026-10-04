import 'dart:io';

import 'package:cli_kit/host/shared/io_tui_terminal.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:xcross/src/composition/cli/runner.dart';
import 'package:xcross/src/composition/native_runtime.dart';
import 'package:xcross/src/shared/tool/tool_alias_operation.dart';

Future<void> main(List<String> args) async {
  try {
    final context = createNativeXcrossContext();
    final aliasCode = await ToolAliasOperation(
      ProcessRunner(
        context.host,
        log: context.log,
        stdinStream: context.stdinStream,
        stdoutSink: context.stdoutSink,
        stderrSink: context.stderrSink,
      ),
    ).run(args, executablePath: context.executable);
    if (aliasCode != null) exit(aliasCode);
    exitCode = await context.runApplication(
      args,
      configTerminal: IoTuiTerminal(input: stdin, output: stdout),
    );
  } on Object catch (error, stackTrace) {
    stderr.writeln(XcrossCli.formatFailure(error, stackTrace));
    exitCode = 1;
  }
}
