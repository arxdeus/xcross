import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:args/command_runner.dart';
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
import 'package:xcross/src/cli/internal/xcross_runner.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross_flutter/xcross_flutter.dart';

/// Namespace for building and running the xcross CLI.
abstract final class XcrossCli {
  static CommandRunner<void> buildRunner() =>
      XcrossRunner(
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

  /// Entry point used by `bin/xcross.dart`.
  static Future<int> run(List<String> args) async {
    final runner = buildRunner();
    _completeArgs(args, runner);
    if (!_ownsStdout(args)) _printCredits();

    try {
      await runner.run(args);
      return 0;
    } on UsageException catch (e) {
      _cliError('$e');
      return 64;
    } on Object catch (error, stackTrace) {
      _reportFailure(error, stackTrace);
      return 1;
    }
  }

  /// Intercepts the shell-driven `xcross completion -- ...` hook and prints
  /// suggestions; calls `exit()` internally and never returns in that case.
  static void _completeArgs(List<String> args, CommandRunner<void> runner) {
    try {
      tryArgsCompletion(args, runner.argParser);
    } on FormatException {
      // Swallow so `runner.run` reports the bad flag as a UsageException
      // instead of a raw stack trace.
    }
  }

  /// Both completion and DAP own stdout as a machine protocol; a credits line
  /// corrupts either stream.
  static bool _ownsStdout(List<String> args) => switch (args) {
    ['completion', ...] => true,
    ['flutter', 'dap', ...] => true,
    _ => false,
  };

  /// One-line credits banner printed before every command dispatch.
  static void _printCredits() {
    if (!Ansi.terminalSupportsAnsi) return;
    final a = Log.ansi;
    Log.logStatus(
      '${a.bold}${a.magenta}xcross${a.none}'
      ' ${a.subtle('· github.com/arxdeus/xcross')}'
      '\n',
    );
  }

  /// Errors carrying a finished user-facing message print without a Dart
  /// stack trace; anything else is a bug and gets the full trace.
  static void _reportFailure(Object error, StackTrace stackTrace) {
    switch (error) {
      case CliError(:final message) ||
          AppleError(:final message) ||
          DarwinSdkError(:final message) ||
          TunnelError(:final message) ||
          FlutterBuildError(:final message) ||
          XcrossError(:final message):
        _cliError('error: $message');
      default:
        _cliError('error: $error');
        _cliError('$stackTrace');
    }
  }

  static void _cliError(String message) => stderr.writeln(message);
}
