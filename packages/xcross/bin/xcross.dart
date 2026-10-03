import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/xcross.dart';

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
