import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_consumer_repair.dart';

final class SwiftPmBuildSession<T extends PlatformHostInterface> implements SwiftPmInteropBuild {
  SwiftPmBuildSession({required this.execution, required this.command, required this.consumerRepair});
  final SwiftPmBuildExecution<T> execution;
  @override
  final SwiftPmBuildCommand command;
  final SwiftPmInteropConsumerRepair<T> consumerRepair;
  @override
  Future<void> build() => execution.execute(command);
  @override
  Future<void> buildTarget(String target) => execution.execute(SwiftPmBuildCommand(executable: command.executable, arguments: [...command.arguments, '--target', target], environment: command.environment, scratchPath: command.scratchPath, targetBuildDir: command.targetBuildDir,ownedRoots:command.ownedRoots,consumerProducts:command.consumerProducts));
  @override
  Future<void> repairConsumers() => consumerRepair.repairSwiftInteropConsumers(targetBuildDir: command.targetBuildDir, consumerProducts: command.consumerProducts);
}
