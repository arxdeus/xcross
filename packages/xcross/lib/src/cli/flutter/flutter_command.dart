import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/cli/flutter/subcommands/dap_command.dart';
import 'package:xcross/src/cli/flutter/subcommands/flutter_build_command.dart';
import 'package:xcross/src/cli/flutter/subcommands/flutter_run_command.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

/// `xcross flutter` — parent command grouping `build`, `run`, and hidden `dap`.
final class FlutterCommand<T extends PlatformHostInterface>
    extends Command<void> {
  FlutterCommand(XcrossRuntime<T> runtime) {
    addSubcommand(FlutterBuildCommand(runtime));
    addSubcommand(FlutterRunCommand(runtime));
    addSubcommand(DapCommand(runtime));
  }

  @override
  String get name => 'flutter';

  @override
  String get description => 'Build and run Flutter iOS apps without Xcode.';
}
