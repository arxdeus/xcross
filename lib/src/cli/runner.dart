import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:completion/completion.dart';
import 'package:xcross/src/cli/completion_command.dart';
import 'package:xcross/src/cli/compose/compose_command.dart';
import 'package:xcross/src/cli/flutter/flutter_command.dart';
import 'package:xcross/src/util/errors.dart';

/// Build the top-level `xcross` command runner.
CommandRunner<void> buildRunner() {
  return CommandRunner<void>(
    'xcross',
    'Build, run, and hot-reload Flutter/KMP iOS apps from Linux without Xcode.',
  )
    ..addCommand(FlutterCommand())
    ..addCommand(ComposeCommand())
    ..addCommand(CompletionCommand());
}

/// Entry point used by `bin/xcross.dart`.
Future<int> runXcross(List<String> args) async {
  final runner = buildRunner();

  // Intercept the shell-driven `xcross completion -- ...` hook and print
  // suggestions. On completion mode this calls `exit()` internally and never
  // returns. Otherwise the ArgResults it returns are discarded and normal
  // command dispatch continues below.
  tryArgsCompletion(args, runner.argParser);

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
