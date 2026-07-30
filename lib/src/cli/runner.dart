import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:completion/completion.dart';
import 'package:xcross/src/cli/completion_command.dart';
import 'package:xcross/src/cli/flutter/flutter_command.dart';
import 'package:xcross/src/cli/ide/dap_command.dart';
import 'package:xcross/src/cli/ide/vscode_command.dart';
import 'package:xcross/src/cli/prepare_command.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Adds a global `-v` so every command can surface its trace output, not just
/// `flutter run` (which keeps its own `-v` for `xcross flutter run -v`).
class _XcrossRunner extends CommandRunner<void> {
  _XcrossRunner(super.executableName, super.description) {
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      help: 'Verbose output (show every command and tool line).',
      negatable: false,
    );
  }

  @override
  Future<void> runCommand(ArgResults topLevelResults) {
    if (topLevelResults.flag('verbose')) setVerbose();
    return super.runCommand(topLevelResults);
  }
}

CommandRunner<void> buildRunner() {
  return _XcrossRunner(
    'xcross',
    'Build, run, and hot-reload Flutter iOS apps from Linux without Xcode.',
  )
    ..addCommand(FlutterCommand())
    ..addCommand(PrepareCommand())
    ..addCommand(DapCommand())
    ..addCommand(VscodeCommand())
    ..addCommand(CompletionCommand());
}

/// Entry point used by `bin/xcross.dart`.
Future<int> runXcross(List<String> args) async {
  final runner = buildRunner();

  // Intercept the shell-driven `xcross completion -- ...` hook and print
  // suggestions. In completion mode this calls `exit()` internally and never
  // returns. Otherwise the ArgResults it returns are discarded and normal
  // command dispatch continues below.
  //
  // Its parse throws on an unknown option, which would surface as a raw stack
  // trace before dispatch ever runs. Swallow it so `runner.run` reports the
  // bad flag as a proper UsageException.
  try {
    tryArgsCompletion(args, runner.argParser);
  } on FormatException {
    // Not our error to report — dispatch below produces the real message.
  }

  try {
    await runner.run(args);
    return 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    return 64;
  } on XcrossError catch (e) {
    stderr.writeln('error: ${e.message}');
    return 1;
  }
}
