import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:cli_util/cli_logging.dart';
import 'package:completion/completion.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/cli/basic/auth_command.dart';
import 'package:xcross/src/cli/basic/completion_command.dart';
import 'package:xcross/src/cli/basic/sdk_command.dart';
import 'package:xcross/src/cli/basic/setup_command.dart';
import 'package:xcross/src/cli/basic/tunnel_command.dart';
import 'package:xcross/src/cli/flutter/flutter_command.dart';
import 'package:xcross/src/cli/ide/ide_command.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross_flutter/xcross_flutter.dart';

part 'runner.g.dart';

/// Global options for the xcross CommandRunner (not a subcommand).
@CliOptions()
class XcrossGlobalArgs {
  @CliOption(
    abbr: 'v',
    help: 'Verbose output (show every command and tool line).',
    negatable: false,
  )
  late bool verbose;
}

/// Adds a global `-v` so every command can surface its trace output, not just
/// `flutter run` (which keeps its own `-v` for `xcross flutter run -v`).
class _XcrossRunner extends CommandRunner<void> {
  _XcrossRunner(super.executableName, super.description) {
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

/// Namespace for building and running the xcross CLI.
abstract final class XcrossCli {
  static CommandRunner<void> buildRunner() {
    return _XcrossRunner(
        'xcross',
        'Build, run, and hot-reload Flutter iOS apps without Xcode.',
      )
      ..addCommand(FlutterCommand())
      ..addCommand(TunnelCommand())
      ..addCommand(SetupCommand())
      ..addCommand(AuthCommand())
      ..addCommand(SdkCommand())
      ..addCommand(IdeCommand())
      ..addCommand(CompletionCommand());
  }

  /// One-line credits banner printed before every command dispatch.
  static void _printCredits() {
    final a = Log.ansi;
    if (Ansi.terminalSupportsAnsi) {
      Log.logStatus(
        '${a.bold}${a.magenta}xcross${a.none}'
        ' ${a.subtle('· github.com/arxdeus/xcross')}'
        '\n',
      );
    }
  }

  /// Entry point used by `bin/xcross.dart`.
  static Future<int> run(List<String> args) async {
    final runner = buildRunner();

    // Intercept the shell-driven `xcross completion -- ...` hook and print
    // suggestions. In completion mode this calls `exit()` internally and never
    // returns. Otherwise the ArgResults it returns are discarded and normal
    // command dispatch continues below.
    //
    // Its parse throws on an unknown option, which would surface as a raw stack
    // trace before dispatch ever runs. Swallow it so `runner.run` reports the
    // bad flag as a proper UsageException.
    try {
      tryArgsCompletion(args, runner.argParser);
    } on FormatException {
      // Not our error to report — dispatch below produces the real message.
    }

    // Both completion and DAP own stdout as a machine protocol; a credits line
    // corrupts either stream.
    final quiet =
        args.isNotEmpty &&
        (args.first == 'completion' ||
            (args.length >= 2 && args[0] == 'flutter' && args[1] == 'dap'));
    if (args.isEmpty || !quiet) {
      _printCredits();
    }

    try {
      await runner.run(args);
      return 0;
    } on UsageException catch (e) {
      _cliError('$e');
      return 64;
    } on CliError catch (e) {
      _cliError('error: ${e.message}');
      return 1;
    } on AppleError catch (e) {
      _cliError('error: ${e.message}');
      return 1;
    } on DarwinSdkError catch (e) {
      _cliError('error: ${e.message}');
      return 1;
    } on TunnelError catch (e) {
      _cliError('error: ${e.message}');
      return 1;
    } on FlutterBuildError catch (e) {
      _cliError('error: ${e.message}');
      return 1;
    } on XcrossError catch (e) {
      _cliError('error: ${e.message}');
      return 1;
    } on Object catch (e, st) {
      _cliError('error: $e');
      _cliError('$st');
      return 1;
    }
  }

  static void _cliError(String message) => stderr.writeln(message);
}
