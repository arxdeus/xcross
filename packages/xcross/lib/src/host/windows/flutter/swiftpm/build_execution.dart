import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/windows_swift_plan_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_consumer_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';

final class WindowsSwiftPmBuildExecution<T extends PlatformHostInterface>
    implements SwiftPmBuildExecution<T> {
  WindowsSwiftPmBuildExecution({
    required this.runner,
    required this.repair,
    required this.sourceRepair,
    required this.consumerRepair,
  });
  final ProcessRunner<T> runner;
  final WindowsSwiftPlanRepair repair;
  final SwiftPmSourceRepair<T> sourceRepair;
  final SwiftPmInteropConsumerRepair<T> consumerRepair;
  @override
  Future<void> execute(SwiftPmBuildCommand command) =>
      sourceRepair.buildWithSwiftUIStateRecovery(
        ownedRoots: command.ownedRoots,
        build: () => executeCommand(command),
      );
  Future<void> executeCommand(SwiftPmBuildCommand command) async {
    try {
      await runner.runChecked(
        command.executable,
        command.arguments,
        environment: command.environment,
        captureAndEcho: true,
        label: 'swift build',
      );
    } on Object {
      if (!await repair.repairWindowsGeneratedBuildFiles(
        command.scratchPath,
        command.targetBuildDir,
      )) {
        rethrow;
      }
      await runner.runChecked(
        command.executable,
        command.arguments,
        environment: command.environment,
        captureAndEcho: true,
        label: 'swift build',
      );
    }
    await repair.repairWindowsGeneratedBuildFiles(
      command.scratchPath,
      command.targetBuildDir,
    );
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
