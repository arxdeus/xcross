import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/flutter/build/internal/windows_swift_plan_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';

final class WindowsSwiftPmBuildExecution<T extends PlatformHostInterface> implements SwiftPmBuildExecution<T> {
  WindowsSwiftPmBuildExecution({required this.runner, required this.repair});
  final ProcessRunner<T> runner;
  final WindowsSwiftPlanRepair repair;
  @override
  Future<void> execute(SwiftPmBuildCommand command) async {
    try {
      await runner.runChecked(command.executable, command.arguments, environment: command.environment, captureAndEcho: true, label: 'swift build');
    } on Object {
      if (!await repair.repairWindowsGeneratedBuildFiles(command.scratchPath, command.targetBuildDir)) rethrow;
      await runner.runChecked(command.executable, command.arguments, environment: command.environment, captureAndEcho: true, label: 'swift build');
    }
    await repair.repairWindowsGeneratedBuildFiles(command.scratchPath, command.targetBuildDir);
  }
@override
Future<void> recoverInterop({required Set<String> emitted,required SwiftPmInteropBuild operation,required Object error,required StackTrace stack}) async {
if(emitted.isEmpty) Error.throwWithStackTrace(error,stack);
try { await operation.repairConsumers(); } on Object { Error.throwWithStackTrace(error,stack); }
await operation.build();
}
}
