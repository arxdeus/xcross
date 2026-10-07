import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

@internal
abstract interface class SwiftPmDependencyPreparation<
  T extends PlatformHostInterface
> {
  Future<void> prepare(SwiftPmDependencyCommand command);
}

@internal
final class SwiftPmDependencyCommand {
  SwiftPmDependencyCommand({
    required this.swift,
    required this.pluginsDir,
    required this.scratchPath,
    required this.swiftSdksPath,
    required this.toolsetPath,
    required this.binaryArtifactStore,
    required this.binaryArtifactFallback,
    required this.swiftPmArtifactJunctionCapability,
    required this.packageLocalArtifactJunctionCapability,
    required Map<String, String>? environment,
    required this.swiftSdkTriple,
  }) : environment = environment == null ? null : Map.unmodifiable(environment);
  final String swift;
  final String pluginsDir;
  final String scratchPath;
  final String swiftSdksPath;
  final String toolsetPath;
  final String binaryArtifactStore;
  final String binaryArtifactFallback;
  final bool swiftPmArtifactJunctionCapability;
  final bool packageLocalArtifactJunctionCapability;
  final Map<String, String>? environment;
  final String swiftSdkTriple;
}
