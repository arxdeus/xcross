import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';

final class SwiftPmBuildSession<T extends PlatformHostInterface> implements SwiftPmInteropBuild {
  SwiftPmBuildSession({required this.execution, required this.command, required this.sourceRepair, required this.interopRepair, required this.ownedRoots, required this.consumerProducts});
  final SwiftPmBuildExecution<T> execution;
  final SwiftPmBuildCommand command;
  final SwiftPmSourceRepair<T> sourceRepair;
  final SwiftPmInteropRepair<T> interopRepair;
  final List<String> ownedRoots;
  final Map<String, Set<String>> consumerProducts;
  @override
  Future<void> build() => sourceRepair.buildWithSwiftUIStateRecovery(ownedRoots: ownedRoots, build: () => execution.execute(command));
  @override
  Future<void> buildTarget(String target) => sourceRepair.buildWithSwiftUIStateRecovery(ownedRoots: ownedRoots, build: () => execution.execute(SwiftPmBuildCommand(executable: command.executable, arguments: [...command.arguments, '--target', target], environment: command.environment, scratchPath: command.scratchPath, targetBuildDir: command.targetBuildDir)));
  @override
  Future<void> repairConsumers() => interopRepair.repairSwiftInteropConsumers(targetBuildDir: command.targetBuildDir, consumerProducts: consumerProducts);
}
