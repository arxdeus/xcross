import 'package:args/command_runner.dart';
import 'package:xcross/src/cli/ide/subcommands/idea_command.dart';
import 'package:xcross/src/cli/ide/subcommands/vscode_command.dart';
import 'package:xcross/src/cli/ide/xcross_executable.dart';

/// `xcross ide` — parent command grouping IDE setup subcommands.
final class IdeCommand extends Command<void> {
  IdeCommand(XcrossIdeLauncher launcher) {
    addSubcommand(VscodeCommand(launcher));
    addSubcommand(IdeaCommand(launcher));
  }

  @override
  String get name => 'ide';

  @override
  String get description =>
      'Set up editor integration for Run & Debug on an iOS device.';
}
