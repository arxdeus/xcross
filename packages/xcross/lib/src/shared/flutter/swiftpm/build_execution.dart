import 'package:cli_kit/cli_kit.dart';

final class SwiftPmBuildCommand {
  SwiftPmBuildCommand({required this.executable, required this.arguments, required this.environment, required this.scratchPath, required this.targetBuildDir});
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String scratchPath;
  final String targetBuildDir;
}

abstract interface class SwiftPmBuildExecution<T extends PlatformHostInterface> {
  Future<void> execute(SwiftPmBuildCommand command);
Future<void> recoverInterop({required Set<String> emitted,required SwiftPmInteropBuild operation,required Object error,required StackTrace stack});
}

abstract interface class SwiftPmInteropBuild {
  Future<void> build();
  Future<void> buildTarget(String target);
  Future<void> repairConsumers();
}
