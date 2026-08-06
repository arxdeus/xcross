import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';

part 'xcross_runner.g.dart';

/// Global options for the xcross CommandRunner (not a subcommand).
@CliOptions()
final class XcrossGlobalArgs {
  @CliOption(
    abbr: 'v',
    help: 'Verbose output (show every command and tool line).',
    negatable: false,
  )
  late bool verbose;
}

/// Adds a global `-v` so every command can surface its trace output, not just
/// `flutter run` (which keeps its own `-v` for `xcross flutter run -v`).
final class XcrossRunner extends CommandRunner<void> {
  XcrossRunner(super.executableName, super.description) {
    _$populateXcrossGlobalArgsParser(argParser);
  }

  @override
  Future<void> runCommand(ArgResults topLevelResults) {
    if (_$parseXcrossGlobalArgsResult(topLevelResults).verbose) {
      Log.setVerbose();
    }
    return super.runCommand(topLevelResults);
  }
}
