import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/cli/compose/compose_build_command.dart';
import 'package:xcross/src/cli/compose/compose_run_command.dart';
import 'package:xcross/src/cli/compose/compose_setup_command.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

final class ComposeCommand<T extends PlatformHostInterface>
    extends Command<void> {
  ComposeCommand(
    XcrossRuntime<T> runtime, {
    ComposeBuildCommand? buildCommand,
    ComposeRunCommand? runCommand,
    ComposeSetupCommand? setupCommand,
  }) {
    addSubcommand(buildCommand ?? ComposeBuildCommand(runtime));
    addSubcommand(runCommand ?? ComposeRunCommand(runtime));
    addSubcommand(setupCommand ?? ComposeSetupCommand(runtime));
  }

  @override
  String get name => 'compose';

  @override
  String get description =>
      'Build and run Compose Multiplatform iOS apps without Xcode.';
}
