import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

@internal
final class SwiftPmBuildCommand {
  SwiftPmBuildCommand({
    required this.executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required this.scratchPath,
    required this.targetBuildDir,
    required Map<String, Set<String>> consumerProducts,
  }) : arguments = List.unmodifiable(arguments),
       environment = Map.unmodifiable(environment),
       consumerProducts = Map.unmodifiable(
         consumerProducts.map(
           (key, value) => MapEntry(key, Set<String>.unmodifiable(value)),
         ),
       );
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String scratchPath;
  final String targetBuildDir;
  final Map<String, Set<String>> consumerProducts;
}

@internal
abstract interface class SwiftPmBuildExecution<
  T extends PlatformHostInterface
> {
  Future<void> execute(SwiftPmBuildCommand command);
  Future<void> recoverInterop({
    required Set<String> emitted,
    required SwiftPmBuildCommand command,
    required Object error,
    required StackTrace stack,
  });
}

@internal
abstract interface class SwiftPmInteropBuild {
  SwiftPmBuildCommand get command;
  Future<void> build();
  Future<void> buildTarget(String target);
  Future<void> buildTargets(List<String> targets);
  Future<void> repairConsumers();
}
