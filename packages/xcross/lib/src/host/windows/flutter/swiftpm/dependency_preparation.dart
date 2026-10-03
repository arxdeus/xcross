import 'package:path/path.dart' as p;
import 'package:xcross/src/host/windows/flutter/swiftpm/pinned_dependency_resolver.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
final class WindowsSwiftPmDependencyPreparation<T extends PlatformHostInterface> implements SwiftPmDependencyPreparation<T> {
WindowsSwiftPmDependencyPreparation({required this.runner});
final ProcessRunner<T> runner;
@override
Future<void> prepare(SwiftPmDependencyPreparationRequest<T> request) async {

    Future<void> resolve() => runner.runChecked(
      request.swift,
      request.processPolicy
          .swiftResolveArguments(
            pluginsDir: request.pluginsDir,
            scratchPath: request.scratchPath,
            swiftSdksPath: request.swiftSdksPath,
            toolsetPath: request.toolsetPath,
            swiftSdkTriple: request.swiftSdkTriple,
          )
          .skip(1)
          .toList(),
      environment: request.environment,
      inheritStdio: runner.log.isVerbose,
      label: 'request.swift package resolve',
    );
    Future<void> resolveWithRetries() => request.binaryRecovery.retryingTransientNetworkFailure(
      resolve,
      label: 'request.swift package resolve',
    );
    final attemptState = SwiftPmBinaryAttemptState();
    final packageIdentities = await request.packageMetadata.packageIdentitiesByDirectory(request.pluginsDir);
    Future<bool> recover() => request.binaryRecovery.stageExtractedBinaryArtifacts(
      scratchPath: request.scratchPath,
      vendorDir: request.vendorDir,
      packageIdentities: packageIdentities,
      binaryArtifactStore: request.binaryArtifactStore,
      binaryArtifactFallback: request.binaryArtifactFallback,
      attemptState: attemptState,
      packageLocalArtifactJunctionCapability:
          request.packageLocalArtifactJunctionCapability,
    );
    await resolveDependencies(recovery: request.binaryRecovery,
      resolve: resolveWithRetries,
      recoverBootstrap: recover,
      materialize: () =>
          request.checkout.materializeCheckoutSymlinks(request.scratchPath),
      normalize: () =>
          request.interopRepair.normalizeResolvedPackageManifests(request.scratchPath),
      recoverFinal: recover,
    );

}
  Future<void> resolveDependencies({
    required SwiftPmBinaryRecovery<T> recovery,
required Future<void> Function() resolve,
    required Future<bool> Function() recoverBootstrap,
    required Future<bool> Function() materialize,
    required Future<bool> Function() normalize,
    required Future<bool> Function() recoverFinal,
  }) async {
    await recovery.resolveWithFinalBinaryRecovery(
      resolve: resolve,
      recover: recoverBootstrap,
    );
    final changed = await materialize() | await normalize();
    if (changed) {
      await recovery.resolveWithFinalBinaryRecovery(
        resolve: resolve,
        recover: recoverFinal,
      );
    }
  }


@override
Future<void> materializeClone(SwiftPmCheckout<T> checkout,String destination,String git,String vendorDir) async {await checkout.materializeGitCheckoutSymlinks(destination,git:git,stampDir:p.join(vendorDir,'.xcross-symlinks'));}
@override
Future<({Map<String,String> pins,Map<String,String> originals})> bootstrapPinned(SwiftPmPinnedDependencyRequest<T> request)=>WindowsSwiftPmPinnedDependencyResolver<T>(runner:request.runner,fileSystem:request.fileSystem,filesystem:request.filesystem,repository:request.repository,manifestNormalizer:request.manifestNormalizer).resolve(request.packageDirectories,request.vendorDir,clonePackage:request.clonePackage);
@override
Future<void> prepareArtifacts(SwiftPmBinaryRecovery<T> recovery,String packageRoot,String store,String fallback,bool capability)=>recovery.prepareSupportedBinaryArtifacts(packageRoot:packageRoot,binaryArtifactStore:store,binaryArtifactFallback:fallback,packageLocalArtifactJunctionCapability:capability);
@override
Future<bool> recoverArtifacts(SwiftPmDependencyArtifactRecoveryRequest<T> request) async {
    final provenance = await request.recovery.binaryArtifactProvenance(
      request.packageRoot,
      request.scratchPath,
      request.dependencies,
    );
    final normalized = await request.interopRepair
        .normalizeResolvedPackageManifests(request.scratchPath);
    final archive = await request.recovery
        .recoverBootstrapBinaryArtifacts(
          scratchPath: request.scratchPath,
          binaryArtifactStore: request.store,
          provenance: provenance,
          attemptState: request.state,
          swiftPmArtifactJunctionCapability: request.capability,
        );
    final extraction = await request.recovery
        .stageExtractedBinaryArtifacts(
          scratchPath: request.scratchPath,
          vendorDir: p.join(request.scratchPath, '.xcross-vendor'),
          binaryArtifactStore: request.store,
          binaryArtifactFallback: request.fallback,
          attemptState: request.state,
        );
    return normalized || archive || extraction;
}
}
