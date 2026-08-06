import 'package:args/command_runner.dart';

import 'package:xcross/src/cli/flutter/subcommands/dap_command.dart';
import 'package:xcross/src/cli/flutter/subcommands/flutter_build_command.dart';
import 'package:xcross/src/cli/flutter/subcommands/flutter_run_command.dart';

/// `xcross flutter` — parent command grouping `build`, `run`, and hidden `dap`.
final class FlutterCommand extends Command<void> {
  FlutterCommand() {
    addSubcommand(FlutterBuildCommand());
    addSubcommand(FlutterRunCommand());
    addSubcommand(DapCommand());
  }

  @override
  String get name => 'flutter';

  @override
  String get description => 'Build and run Flutter iOS apps without Xcode.';
}
