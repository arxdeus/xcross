import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';

final class PosixSwiftPmBuildExecution<T extends PlatformHostInterface> implements SwiftPmBuildExecution<T> {
  PosixSwiftPmBuildExecution({required this.runner});
  final ProcessRunner<T> runner;
  @override
  Future<void> execute(SwiftPmBuildCommand command) => runner.runChecked(command.executable, command.arguments, environment: command.environment, label: 'swift build');
@override
Future<void> recoverInterop({required Set<String> emitted,required SwiftPmInteropBuild operation,required Object error,required StackTrace stack}) async { Error.throwWithStackTrace(error,stack); }
}
