import 'package:apple_developer_kit/apple_developer_kit_shared.dart'
    show AppleError;
import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:completion/completion.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart'
    show DevicePrepare, PymdDeviceDiagnostics;
import 'package:dart_mobile_device/dart_mobile_device_shared.dart'
    show TunnelError;
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/cli/basic/auth_command.dart';
import 'package:xcross/src/cli/basic/clean_command.dart';
import 'package:xcross/src/cli/basic/completion_command.dart';
import 'package:xcross/src/cli/basic/config_command.dart';
import 'package:xcross/src/cli/basic/doctor_command.dart';
import 'package:xcross/src/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/cli/basic/doctor_project_checks.dart';
import 'package:xcross/src/cli/basic/sdk_command.dart';
import 'package:xcross/src/cli/basic/setup_command.dart';
import 'package:xcross/src/cli/basic/tunnel_command.dart';
import 'package:xcross/src/cli/basic/update_command.dart';
import 'package:xcross/src/cli/compose/compose_command.dart';
import 'package:xcross/src/cli/flutter/flutter_command.dart';
import 'package:xcross/src/cli/ide/ide_command.dart';
import 'package:xcross/src/cli/ide/xcross_executable.dart';
import 'package:xcross/src/cli/internal/xcross_runner.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/composition/xcross_application.dart';
import 'package:xcross/src/config/config.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/flutter.dart' show FlutterBuildError;
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/self_update.dart';
import 'package:xcross/src/update/update_check.dart';

/// Namespace for building and running the xcross CLI.
abstract final class XcrossCli {
  static CommandRunner<void> buildRunner<T extends PlatformHostInterface>(
    XcrossApplication<T> application, {
    required TuiTerminal configTerminal,
    Iterable<String> excludedCommands = const [],
  }) {
    final runtime = application.runtime;
    final pymd = application.pymd;
    final excluded = excludedCommands
        .map((command) => command.trim().toLowerCase())
        .toSet();
    final runner = XcrossRunner(
      runtime.log,
      'xcross',
      'Build and run Flutter and Compose Multiplatform iOS apps without Xcode.',
    );
    final physical = composePhysicalFeatures(runtime);
    final environmentChecks = DoctorEnvironmentChecks(
      createAppleHttpClient: runtime.createAppleHttpClient,
      hostPlatform: runtime.host,
      runner: runtime.runner,
      repository: runtime.sdkRepository,
      toolchain: runtime.darwinToolchain,
      deviceDiagnostics: PymdDeviceDiagnostics(pymd),
      buildPlatform: physical.target.buildPlatform,
      appleHostServices: runtime.appleHostServices,
      sdkMismatch: runtime.sdkInstall.hostToolchainMismatch,
      sdkToolchainIdentity: runtime.sdkInstall.hostToolchainIdentity,
    );
    final ideLauncher = XcrossIdeLauncher(
      host: runtime.host,
      log: runtime.log,
      executable: runtime.executable,
      configPath: runtime.config.configPath,
      flutterRoot:
          runtime.config.roots?.flutterSdk ??
          runtime.config.config?.environment['FLUTTER_ROOT'] as String?,
      declarative: runtime.config.isConfigured,
    );
    final commands = <Command<void>>[
      FlutterCommand(runtime, pymd, application.sockets),
      ComposeCommand(runtime, pymd, application.sockets),
      TunnelCommand(DevicePrepare(pymd)),
      CleanCommand(
        projectRoot: runtime.host.paths.context.current,
        log: runtime.log,
        policy: physical.flutterRuntime.policy,
        environment: runtime.runner.effectiveEnvironment,
      ),
      ConfigCommand(
        terminal: configTerminal,
        writeLine: runtime.log.output.stdout,
        store: XcrossConfigStore(runtime.host, policy: runtime.configPolicy),
      ),
      DoctorCommand(
        DoctorExaminer(
          projectRoot: runtime.host.paths.context.current,
          environmentChecks: environmentChecks,
          projectChecks: DoctorProjectChecks(runtime),
        ),
        log: runtime.log,
      ),
      SetupCommand(
        host: runtime.host,
        runner: runtime.runner,
        requirements: runtime.operations.setupRequirements,
        scriptPolicy: runtime.operations.setupScript,
        createHttpClient: runtime.createHttpClient,
        swiftInstallGuidance: runtime.operations.swiftInstallGuidance,
        setupSource: runtime.config.config?.setup,
      ),
      AuthCommand(
        commandPrompt: runtime.commandPrompt,
        createAdiHttpClient: runtime.createHttpClient,
        createHttpClient: runtime.createAppleHttpClient,
        log: runtime.log,
        hostServices: runtime.appleHostServices,
        createNativeLibraryLoader: runtime.createNativeLibraryLoader,
      ),
      SdkCommand(runtime.sdkInstall),
      IdeCommand(ideLauncher),
      UpdateCommand(runtime),
      CompletionCommand(write: runtime.log.output.write),
    ];
    for (final command in commands) {
      if (!excluded.contains(command.name.toLowerCase())) {
        runner.addCommand(command);
      }
    }
    return runner;
  }

  /// Entry point used by `bin/xcross.dart`.
  static Future<int> run<T extends PlatformHostInterface>(
    List<String> args,
    XcrossApplication<T> application, {
    required TuiTerminal configTerminal,
  }) async {
    final runtime = application.runtime;
    final excludedCommands =
        runtime.config.config?.excludedCommands ?? const <String>{};
    final runner = buildRunner(
      application,
      configTerminal: configTerminal,
      excludedCommands: excludedCommands,
    );
    _completeArgs(args, runner);
    final ownsStdout = ownsMachineStdout(args, runner);
    if (!ownsStdout) _printCredits(runtime.log);

    final updateCheck = UpdateCheck(
      runtime.host,
      log: runtime.log,
      releaseLookup: runtime.releaseLookup,
      outputHasTerminal: runtime.outputHasTerminal,
    );
    final checkUpdates = updateCheck.isEnabled(ownsStdout: ownsStdout);
    if (checkUpdates) updateCheck.printHintFromCache();

    try {
      await runner.run(args);
      return 0;
    } on UsageException catch (e) {
      runtime.log.output.stderr('$e');
      return 64;
    } on Object catch (error, stackTrace) {
      runtime.log.output.stderr(formatFailure(error, stackTrace));
      return 1;
    } finally {
      // After the command, never before: neither of these is worth a millisecond
      // of startup latency, and the sweep is deliberately not tied to the
      // update-check opt-out, which says nothing about disk hygiene.
      try {
        if (!SelfUpdate.isVerificationProcess(
          runtime.runner.effectiveEnvironment,
        )) {
          SelfUpdate.sweepStaleBackups(
            InstallLayout.resolve(runtime.executable, host: runtime.host),
          );
        }
      } on Object {
        // Best effort cleanup. Update completion should not be blocked by stale backup cleanup.
      }
      if (checkUpdates) await updateCheck.refreshIfStale();
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
  static bool ownsMachineStdout(List<String> args, CommandRunner<void> runner) {
    try {
      final command = runner.argParser.parse(args).command;
      return command?.name == 'completion' ||
          command?.name == 'flutter' && command?.command?.name == 'dap';
    } on FormatException {
      return false;
    }
  }

  /// One-line credits banner printed before every command dispatch.
  static void _printCredits(Log log) {
    if (!log.ansi.useAnsi) return;
    final a = log.ansi;
    // log.dim (SGR 2) instead of Ansi.subtle: cli_util's gray (`1;30`) maps to
    // the background color on many dark palettes and rendered invisible.
    log.logStatus(
      '${a.bold}${a.magenta}xcross${a.none}'
      ' ${log.dim('· github.com/arxdeus/xcross')}'
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
}
