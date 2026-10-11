import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/host/windows/flutter/swiftpm/windows_swift_plan_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_consumer_repair.dart';

@internal
final class WindowsSwiftPmBuildExecution<T extends PlatformHostInterface>
    implements SwiftPmBuildExecution<T> {
  WindowsSwiftPmBuildExecution({
    required this.runner,
    required this.repair,
    required this.consumerRepair,
    this.moduleCacheRaceAttempts = 3,
  });
  final ProcessRunner<T> runner;
  final WindowsSwiftPlanRepair repair;
  final SwiftPmInteropConsumerRepair<T> consumerRepair;

  /// How many times one `swift build` runs when it keeps losing a Clang
  /// module cache race (see [isModuleCacheRace]).
  final int moduleCacheRaceAttempts;

  /// Whether a failed `swift build` lost a race on the shared implicit Clang
  /// module cache rather than hitting a genuine compile error.
  ///
  /// Implicit module locks are disabled on Windows (they deadlock there, see
  /// `SwiftPmBuildPlan.noImplicitModuleLockArguments`), so parallel frontends
  /// build the same SDK module at once. On Windows the losing frontend then
  /// either cannot replace the `.pcm` the winner holds open ("unable to open
  /// output file ... operation not permitted") or sees the module twice under
  /// the same path ("module 'UIKit' is defined in both X and X"). Both were
  /// seen on windows-2022 and windows-11-arm and pass on a re-run.
  static bool isModuleCacheRace(Object error) {
    final text = error.toString().toLowerCase();
    // Our own timeout already waited the full budget.
    if (text.contains('and was killed')) return false;
    final lostOutput = RegExp(
      r"unable to open output file '[^']*\.pcm': "
      "'(?:operation not permitted|permission denied)",
    );
    final duplicated = RegExp(
      r"is defined in both '[^']*\.pcm' and '[^']*\.pcm'",
    );
    return lostOutput.hasMatch(text) || duplicated.hasMatch(text);
  }

  @override
  Future<void> execute(SwiftPmBuildCommand command) => executeCommand(command);
  Future<void> executeCommand(SwiftPmBuildCommand command) async {
    try {
      await _build(command);
    } on Object {
      if (!await repair.repairWindowsGeneratedBuildFiles(
        command.scratchPath,
        command.targetBuildDir,
      )) {
        rethrow;
      }
      await _build(command);
    }
    await repair.repairWindowsGeneratedBuildFiles(
      command.scratchPath,
      command.targetBuildDir,
    );
  }

  Future<void> _build(SwiftPmBuildCommand command) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await runner.runChecked(
          command.executable,
          command.arguments,
          environment: command.environment,
          captureAndEcho: true,
          label: 'swift build',
        );
      } on Object catch (error) {
        if (attempt >= moduleCacheRaceAttempts || !isModuleCacheRace(error)) {
          rethrow;
        }
        runner.log.logTrace(
          'swift build lost a Clang module cache race (attempt $attempt of '
          '$moduleCacheRaceAttempts), clearing the module cache and retrying',
        );
        await _clearModuleCache(command.targetBuildDir);
      }
    }
  }

  /// Drops the implicit module cache so the retry rebuilds every `.pcm` from
  /// scratch instead of tripping over the half-written or duplicated one.
  Future<void> _clearModuleCache(String targetBuildDir) async {
    final cache = runner.host.fileSystem.directory(
      p.join(targetBuildDir, 'ModuleCache'),
    );
    try {
      if (cache.existsSync()) await cache.delete(recursive: true);
    } on Object catch (error) {
      // A file still held open is not fatal: the retry rebuilds around it.
      runner.log.logTrace('could not clear ${cache.path}: $error');
    }
  }

  @override
  Future<void> recoverInterop({
    required Set<String> emitted,
    required SwiftPmBuildCommand command,
    required Object error,
    required StackTrace stack,
  }) async {
    if (emitted.isEmpty) Error.throwWithStackTrace(error, stack);
    try {
      await consumerRepair.repairSwiftInteropConsumers(
        targetBuildDir: command.targetBuildDir,
        consumerProducts: command.consumerProducts,
      );
    } on Object {
      Error.throwWithStackTrace(error, stack);
    }
    await execute(command);
  }
}
