import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

abstract interface class SwiftPmDependencyPreparation<
  T extends PlatformHostInterface
> {
  Future<void> prepare(SwiftPmDependencyCommand command);
  Future<void> materializeClone(
    String destination,
    String git,
    String vendorDir,
  );
  Future<({Map<String, String> pins, Map<String, String> originals})>
  bootstrapPinned(SwiftPmPinnedDependencyCommand command);
  Future<void> prepareArtifacts(
    String packageRoot,
    String store,
    String fallback, {
    required bool capability,
  });
  Future<bool> recoverArtifacts(SwiftPmDependencyArtifactCommand command);
}

final class SwiftPmDependencyCommand {
  SwiftPmDependencyCommand({
    required this.swift,
    required this.pluginsDir,
    required this.scratchPath,
    required this.swiftSdksPath,
    required this.toolsetPath,
    required this.vendorDir,
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
  final String vendorDir;
  final String binaryArtifactStore;
  final String binaryArtifactFallback;
  final bool swiftPmArtifactJunctionCapability;
  final bool packageLocalArtifactJunctionCapability;
  final Map<String, String>? environment;
  final String swiftSdkTriple;
}

final class SwiftPmPinnedDependencyCommand {
  SwiftPmPinnedDependencyCommand({
    required Iterable<String> packageDirectories,
    required this.vendorDir,
  }) : packageDirectories = List.unmodifiable(packageDirectories);
  final List<String> packageDirectories;
  final String vendorDir;
}

final class SwiftPmDependencyArtifactCommand {
  SwiftPmDependencyArtifactCommand({
    required this.packageRoot,
    required this.scratchPath,
    required this.store,
    required this.fallback,
    required List<SwiftPmPackageDependency> dependencies,
    required this.state,
    required this.capability,
  }) : dependencies = List.unmodifiable(dependencies);
  final String packageRoot;
  final String scratchPath;
  final String store;
  final String fallback;
  final List<SwiftPmPackageDependency> dependencies;
  final SwiftPmBinaryAttemptState state;
  final bool capability;
}
