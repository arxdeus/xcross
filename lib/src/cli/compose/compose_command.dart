import 'package:args/command_runner.dart';
import 'package:xcross/src/cli/compose/compose_build_args.dart';
import 'package:xcross/src/cli/compose/compose_run_args.dart';
import 'package:xcross/src/cli/compose/compose_setup_args.dart';

/// `xcross compose` — parent command grouping `build` and `run` for
/// Kotlin (Compose) Multiplatform iOS apps.
///
/// Mirrors ComposeCommand from ComposeCommand.swift.
class ComposeCommand extends Command<void> {
  ComposeCommand() {
    addSubcommand(ComposeBuildCommand());
    addSubcommand(ComposeRunCommand());
    addSubcommand(ComposeSetupCommand());
  }

  @override
  String get name => 'compose';

  @override
  String get description =>
      'Build and run Kotlin (Compose) Multiplatform iOS apps from Linux, '
      'driving the original xtool.';
}
