@internal
library;

import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/runtime/version.dart';

part 'xcross_runner.g.dart';

/// Global options for the xcross CommandRunner (not a subcommand).
@internal
@CliOptions()
final class XcrossGlobalArgs {
  @CliOption(
    abbr: 'v',
    help: 'Verbose output (show every command and tool line).',
    negatable: false,
  )
  late bool verbose;

  @CliOption(help: 'Print the xcross version and exit.', negatable: false)
  late bool version;
}

/// Adds a global `-v` so every command can surface its trace output, not just
/// `flutter run` (which keeps its own `-v` for `xcross flutter run -v`).
@internal
final class XcrossRunner extends CommandRunner<void> {
  XcrossRunner(this.log, super.executableName, super.description) {
    _$populateXcrossGlobalArgsParser(argParser);
  }

  /// `--version` has to be handled here rather than in [runCommand], which a
  /// bare `xcross --version` never reaches: CommandRunner rejects the missing
  /// subcommand first.
  final Log log;

  @override
  Future<void> run(Iterable<String> args) async {
    if (_wantsVersion(args)) {
      log.logStatus(XcrossVersion.describe());
      return;
    }
    return super.run(args);
  }

  /// Bad input is left for [CommandRunner] to reject, so it still surfaces as
  /// a UsageException with the full help text.
  bool _wantsVersion(Iterable<String> args) {
    try {
      return _$parseXcrossGlobalArgsResult(argParser.parse(args)).version;
    } on FormatException {
      return false;
    }
  }

  @override
  Future<void> runCommand(ArgResults topLevelResults) {
    if (_$parseXcrossGlobalArgsResult(topLevelResults).verbose) {
      log.setVerbose();
    }
    return super.runCommand(topLevelResults);
  }
}
