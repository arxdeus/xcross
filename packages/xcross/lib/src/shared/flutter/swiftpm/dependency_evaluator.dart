import 'dart:async';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/network_retry.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmDependencyEvaluator<T extends PlatformHostInterface> {
  SwiftPmDependencyEvaluator({
    required this.artifactFileSystem,
    required this.dependencyPreparation,
    required this.hostPolicy,
    required this.networkRetry,
    required this.sourceRepair,
  });
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmDependencyPreparation<T> dependencyPreparation;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmNetworkRetry<T> networkRetry;
  final SwiftPmSourceRepair<T> sourceRepair;
  Future<Map<String, String>> evaluateDependencyRefsWithRecovery(
    String packageDirectory, {
    required Future<void> Function(String packageDirectory) resolve,
    required Future<bool> Function(
      String packageDirectory,
      SwiftPmBinaryAttemptState attemptState,
    )
    recover,
    required SwiftPmBinaryAttemptState attemptState,
  }) async {
    final resolvedFile = artifactFileSystem.file(
      p.join(packageDirectory, 'Package.resolved'),
    );
    if (resolvedFile.existsSync()) await resolvedFile.delete();
    try {
      await resolve(packageDirectory);
    } on Object {
      if (!await recover(packageDirectory, attemptState)) rethrow;
      await resolve(packageDirectory);
    }
    try {
      return SwiftPmBinaryProvenance.dependencyRefsFromPackageResolved(
        await resolvedFile.readAsString(),
      );
    } on Object catch (error) {
      throw FlutterBuildError('Cannot read ${resolvedFile.path}: $error');
    }
  }

  static String? dependencyResolverScratchPath({
    required String packageDirectory,
    required String? scratchPath,
    required bool usesDefaultResolver,
  }) => usesDefaultResolver ? p.join(packageDirectory, '.build') : scratchPath;

  Future<Map<String, String>> evaluatedDependencyRefs(
    String packageDirectory,
    Future<String> Function(String name) locateTool, {
    Future<void> Function(String packageDirectory)? resolve,
    Future<bool> Function(
      String packageDirectory,
      SwiftPmBinaryAttemptState attemptState,
    )?
    recover,
    SwiftPmBinaryAttemptState? attemptState,
    String? scratchPath,
    String? binaryArtifactStore,

    String? binaryArtifactFallback,
    bool swiftPmArtifactJunctionCapability = false,
    List<SwiftPmPackageDependency> dependencies = const [],
  }) async {
    final swift = await locateTool(hostPolicy.packageTool);
    final runResolve =
        resolve ??
        (directory) => networkRetry.retryingTransientNetworkFailure(
          () => sourceRepair.resolveOnce(swift, directory),
          label: 'swift package resolve',
        );
    // `swift package --package-path <directory> resolve` uses
    // `<directory>/.build`; it does not share the final build's explicit
    // scratch path. Recovery must inspect the checkouts and artifacts from
    // this resolver invocation, not `workspace.scratch`.
    final resolverScratchPath =
        SwiftPmDependencyEvaluator.dependencyResolverScratchPath(
          packageDirectory: packageDirectory,
          scratchPath: scratchPath,
          usesDefaultResolver: resolve == null,
        );
    final canRecover =
        resolverScratchPath != null &&
        binaryArtifactStore != null &&
        binaryArtifactFallback != null;
    return evaluateDependencyRefsWithRecovery(
      packageDirectory,
      resolve: runResolve,
      recover:
          recover ??
          (_, state) async {
            if (!canRecover) return false;
            return dependencyPreparation.recoverArtifacts(
              SwiftPmDependencyArtifactCommand(
                packageRoot: packageDirectory,
                scratchPath: resolverScratchPath,
                store: binaryArtifactStore,
                fallback: binaryArtifactFallback,
                dependencies: dependencies,
                state: state,
                capability: swiftPmArtifactJunctionCapability,
              ),
            );
          },
      attemptState: attemptState ?? SwiftPmBinaryAttemptState(),
    );
  }
}
