import 'dart:io';

import 'package:cli_kit/host/shared/io_tui_terminal.dart';
import 'package:xcross/src/composition/cli/runner.dart';
import 'package:xcross/src/composition/native_runtime.dart';

Future<void> main(List<String> args) async {
  try {
    final context = createNativeXcrossContext();
    final aliasCode = await context.toolAliases.run(
      args,
      executablePath: context.executable,
    );
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
