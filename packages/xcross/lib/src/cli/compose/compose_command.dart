import 'package:args/command_runner.dart';

import 'package:xcross/src/cli/compose/compose_build_command.dart';
import 'package:xcross/src/cli/compose/compose_run_command.dart';
import 'package:xcross/src/cli/compose/compose_setup_command.dart';

final class ComposeCommand extends Command<void> {
  ComposeCommand({
    ComposeBuildCommand? buildCommand,
    ComposeRunCommand? runCommand,
    ComposeSetupCommand? setupCommand,
  }) {
    addSubcommand(buildCommand ?? ComposeBuildCommand());
    addSubcommand(runCommand ?? ComposeRunCommand());
    addSubcommand(setupCommand ?? ComposeSetupCommand());
  }

  @override
  String get name => 'compose';

  @override
  String get description =>
      'Build and run Compose Multiplatform iOS apps without Xcode.';
}
