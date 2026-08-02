import 'package:args/command_runner.dart';

import 'package:xcross/src/cli/ide/idea_command.dart';
import 'package:xcross/src/cli/ide/vscode_command.dart';

/// `xcross ide` — parent command grouping IDE setup subcommands.
class IdeCommand extends Command<void> {
  IdeCommand() {
    addSubcommand(VscodeCommand());
    addSubcommand(IdeaCommand());
  }

  @override
  String get name => 'ide';

  @override
  String get description =>
      'Set up editor integration for Run & Debug on an iOS device.';
}
