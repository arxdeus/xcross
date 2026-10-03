import 'package:cli_kit/cli_kit_shared.dart';

final class SwiftPmBuildCommand {
  SwiftPmBuildCommand({required this.executable, required List<String> arguments, required Map<String, String> environment, required this.scratchPath, required this.targetBuildDir, required List<String> ownedRoots, required Map<String, Set<String>> consumerProducts}) : arguments=List.unmodifiable(arguments),environment=Map.unmodifiable(environment),ownedRoots=List.unmodifiable(ownedRoots),consumerProducts=Map.unmodifiable(consumerProducts.map((key,value)=>MapEntry(key,Set<String>.unmodifiable(value))));
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String scratchPath;
  final String targetBuildDir;
  final List<String> ownedRoots;
  final Map<String,Set<String>> consumerProducts;
}

abstract interface class SwiftPmBuildExecution<T extends PlatformHostInterface> {
  Future<void> execute(SwiftPmBuildCommand command);
  Future<void> recoverInterop({required Set<String> emitted,required SwiftPmBuildCommand command,required Object error,required StackTrace stack});
}

abstract interface class SwiftPmInteropBuild {
  SwiftPmBuildCommand get command;
  Future<void> build();
  Future<void> buildTarget(String target);
  Future<void> repairConsumers();
}
