import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';

final class PosixSwiftPmBuildExecution<T extends PlatformHostInterface> implements SwiftPmBuildExecution<T> {
  PosixSwiftPmBuildExecution({required this.runner,required this.sourceRepair});
  final ProcessRunner<T> runner;
  final SwiftPmSourceRepair<T> sourceRepair;
  @override
  Future<void> execute(SwiftPmBuildCommand command) => sourceRepair.buildWithSwiftUIStateRecovery(ownedRoots:command.ownedRoots,build:()=>runner.runChecked(command.executable, command.arguments, environment: command.environment, label: 'swift build'));
@override
Future<void> recoverInterop({required Set<String> emitted,required SwiftPmBuildCommand command,required Object error,required StackTrace stack}) => Future<void>.error(error,stack);
}
