import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:cli_util/cli_logging.dart';
import 'package:completion/completion.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/auth_command.dart';
import 'package:xcross/src/cli/basic/clean_command.dart';
import 'package:xcross/src/cli/basic/completion_command.dart';
import 'package:xcross/src/cli/basic/config_command.dart';
import 'package:xcross/src/cli/basic/doctor_command.dart';
import 'package:xcross/src/cli/basic/sdk_command.dart';
import 'package:xcross/src/cli/basic/setup_command.dart';
import 'package:xcross/src/cli/basic/tunnel_command.dart';
import 'package:xcross/src/cli/basic/update_command.dart';
import 'package:xcross/src/cli/compose/compose_command.dart';
import 'package:xcross/src/cli/flutter/flutter_command.dart';
import 'package:xcross/src/cli/ide/ide_command.dart';
import 'package:xcross/src/cli/internal/xcross_runner.dart';
import 'package:xcross/src/config/config.dart';
import 'package:xcross/src/config/runtime_config.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/flutter.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/self_update.dart';
import 'package:xcross/src/update/update_check.dart';

typedef ToolAliasRun =
    Future<int> Function(String executable, List<String> arguments);

Future<int?> runPreparedToolAlias(
  List<String> arguments, {
  String? executablePath,
  Map<String, String>? environment,
  ToolAliasRun? run,
}) async {
  final path = executablePath ?? Platform.resolvedExecutable;
  final name =
      (path.contains(r'\')
              ? p.windows.basenameWithoutExtension(path)
              : p.basenameWithoutExtension(path))
          .toLowerCase();
  if (name == 'plutil') return runPlutilAlias(arguments);
  final variable = _toolAliasVariables[name];
  if (variable == null) return null;

  final mapping = File('$path.path');
  final target = mapping.existsSync()
      ? mapping.readAsStringSync().trim()
      : (environment ?? Platform.environment)[variable];
  if (target == null || target.isEmpty) {
    stderr.writeln('error: missing trusted tool mapping $variable');
    return 1;
  }
  final invoke = run ?? _runToolAlias;
  // dsymutil (unlike ld/strip/libtool/clang) is not on every LLVM
  // distribution: the swift.org Windows LLVM installer's LLVM/bin has
  // ld64.lld.exe and llvm-strip.exe but no dsymutil.exe (confirmed against
  // a real CI run — Process.start fails with "The system cannot find the
  // file specified"). Kotlin/Native's MacOSBasedLinker calls dsymutil
  // unconditionally after every framework link and fails the whole compile
  // on any nonzero exit, but nothing downstream in xcross reads the
  // resulting .dSYM bundle, so a missing dsymutil should degrade to a
  // silent no-op instead of a build failure.
  if (name == 'dsymutil' && !File(target).existsSync()) {
    return 0;
  }
  final prefix = File('$path.args');
  final forwarded = prefix.existsSync() && _isAppleCompilerInvocation(arguments)
      ? [
          ...(jsonDecode(prefix.readAsStringSync()) as List).cast<String>(),
          ...arguments,
        ]
      : arguments;
  return invoke(target, forwarded);
}

bool _isAppleCompilerInvocation(List<String> arguments) {
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '-arch' ||
        argument.startsWith('-arch=') ||
        argument.startsWith('-miphoneos-version-min=') ||
        argument.startsWith('-mios-simulator-version-min=')) {
      return true;
    }
    if ((argument == '-target' || argument == '--target') &&
        index + 1 < arguments.length &&
        arguments[index + 1].contains('-apple-')) {
      return true;
    }
    if ((argument.startsWith('-target=') || argument.startsWith('--target=')) &&
        argument.contains('-apple-')) {
      return true;
    }
  }
  return false;
}

Future<int> runPlutilAlias(List<String> arguments) async {
  if (arguments case [
    '-replace',
    'MinimumOSVersion',
    '-string',
    final String version,
    final String path,
  ]) {
    final file = File(path);
    if (!file.existsSync()) return 1;
    final original = await file.readAsString();
    final pattern = RegExp(
      r'<key>MinimumOSVersion</key>\s*<string>[^<]*</string>',
    );
    if (!pattern.hasMatch(original)) return 1;
    await file.writeAsString(
      original.replaceFirst(
        pattern,
        '<key>MinimumOSVersion</key>\n\t<string>$version</string>',
      ),
    );
    return 0;
  }
  return 1;
}

Future<int> _runToolAlias(String executable, List<String> arguments) async {
  final process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows && executable.endsWith('.bat'),
  );
  return process.exitCode;
}

const _toolAliasVariables = {
  'ld': 'XCROSS_APPLE_TOOL_LD',
  'strip': 'XCROSS_APPLE_TOOL_STRIP',
  'dsymutil': 'XCROSS_APPLE_TOOL_DSYMUTIL',
  'libtool': 'XCROSS_APPLE_TOOL_LIBTOOL',
  'clang': 'XCROSS_APPLE_TOOL_CLANG',
  'clang++': 'XCROSS_APPLE_TOOL_CLANGXX',
  'cc': 'XCROSS_APPLE_TOOL_CC',
  'ar': 'XCROSS_APPLE_TOOL_AR',
};

/// Namespace for building and running the xcross CLI.
abstract final class XcrossCli {
  static CommandRunner<void> buildRunner({
    Iterable<String> excludedCommands = const [],
  }) {
    final excluded = excludedCommands
        .map((command) => command.trim().toLowerCase())
        .toSet();
    final runner = XcrossRunner(
      'xcross',
      'Build and run Flutter and Compose Multiplatform iOS apps without Xcode.',
    );
    final commands = <Command<void>>[
      FlutterCommand(),
      ComposeCommand(),
      TunnelCommand(),
      CleanCommand(),
      ConfigCommand(),
      DoctorCommand(),
      SetupCommand(),
      AuthCommand(),
      SdkCommand(),
      IdeCommand(),
      UpdateCommand(),
      CompletionCommand(),
    ];
    for (final command in commands) {
      if (!excluded.contains(command.name.toLowerCase())) {
        runner.addCommand(command);
      }
    }
    return runner;
  }

  /// Entry point used by `bin/xcross.dart`.
  static Future<int> run(List<String> args) async {
    final excludedCommands = XcrossRuntimeConfig.isInitialized
        ? XcrossRuntimeConfig.current.config?.excludedCommands ??
              const <String>{}
        : const <String>{};
    final runner = buildRunner(excludedCommands: excludedCommands);
    _completeArgs(args, runner);
    final ownsStdout = _ownsStdout(args);
    if (!ownsStdout) _printCredits();

    final checkUpdates = UpdateCheck.isEnabled(ownsStdout: ownsStdout);
    if (checkUpdates) UpdateCheck.printHintFromCache();

    try {
      await runner.run(args);
      return 0;
    } on UsageException catch (e) {
      _cliError('$e');
      return 64;
    } on Object catch (error, stackTrace) {
      _reportFailure(error, stackTrace);
      return 1;
    } finally {
      // After the command, never before: neither of these is worth a millisecond
      // of startup latency, and the sweep is deliberately not tied to the
      // update-check opt-out, which says nothing about disk hygiene.
      try {
        if (!SelfUpdate.isVerificationProcess()) {
          SelfUpdate.sweepStaleBackups(InstallLayout.resolve());
        }
      } on Object {
        // Best effort cleanup. Update completion should not be blocked by stale backup cleanup.
      }
      if (checkUpdates) await UpdateCheck.refreshIfStale();
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

  /// Formats errors consistently for the CLI entrypoint and command runner.
  /// User-facing errors omit a Dart stack trace; unexpected failures retain it.
  static String formatFailure(Object error, StackTrace stackTrace) {
    return switch (error) {
      CliError(:final message) ||
      AppleError(:final message) ||
      DarwinSdkError(:final message) ||
      TunnelError(:final message) ||
      FlutterBuildError(:final message) ||
      XcrossError(:final message) => 'error: $message',
      XcrossConfigException(:final message, :final path) =>
        'error: ${path == null ? message : '$path: $message'}',
      _ => 'error: $error\n$stackTrace',
    };
  }

  static void _reportFailure(Object error, StackTrace stackTrace) =>
      _cliError(formatFailure(error, stackTrace));

  static void _cliError(String message) => stderr.writeln(message);
}
