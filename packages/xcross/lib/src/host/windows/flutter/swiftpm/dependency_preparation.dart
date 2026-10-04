import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/host/windows/flutter/swiftpm/pinned_dependency_resolver.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/extracted_artifact_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/network_retry.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';

final class WindowsSwiftPmDependencyPreparation<T extends PlatformHostInterface>
    implements SwiftPmDependencyPreparation<T> {
  WindowsSwiftPmDependencyPreparation({
    required this.runner,
    required this.checkout,
    required this.fileSystem,
    required this.manifestNormalizer,
    required this.metadata,
    required this.processPolicy,
    required this.networkRetry,
    required this.binaryPreparation,
    required this.binaryRecovery,
    required this.binaryProvenance,
    required this.extractedArtifacts,
    required this.pinnedResolver,
  });
  final ProcessRunner<T> runner;
  final SwiftPmCheckout<T> checkout;
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmCheckoutManifestNormalizer<T> manifestNormalizer;
  final SwiftPmPackageMetadata metadata;
  final SwiftPmProcessPolicy<T> processPolicy;
  final SwiftPmNetworkRetry<T> networkRetry;
  final SwiftPmBinaryPreparation<T> binaryPreparation;
  final SwiftPmBinaryRecovery<T> binaryRecovery;
  final SwiftPmBinaryProvenance<T> binaryProvenance;
  final SwiftPmExtractedArtifactRecovery<T> extractedArtifacts;
  final WindowsSwiftPmPinnedDependencyResolver<T> pinnedResolver;
  @override
  Future<void> prepare(SwiftPmDependencyCommand command) async {
    Future<void> resolve() => runner.runChecked(
      command.swift,
      processPolicy
          .swiftResolveArguments(
            pluginsDir: command.pluginsDir,
            scratchPath: command.scratchPath,
            swiftSdksPath: command.swiftSdksPath,
            toolsetPath: command.toolsetPath,
            swiftSdkTriple: command.swiftSdkTriple,
          )
          .toList(),
      environment: command.environment,
      inheritStdio: runner.log.isVerbose,
      label: 'swift package resolve',
    );
    Future<void> resolveWithRetries() =>
        networkRetry.retryingTransientNetworkFailure(
          resolve,
          label: 'swift package resolve',
        );
    final attemptState = SwiftPmBinaryAttemptState();
    final packageIdentities = await metadata.packageIdentitiesByDirectory(
      command.pluginsDir,
    );
    Future<bool> recover() => extractedArtifacts.stageExtractedBinaryArtifacts(
      scratchPath: command.scratchPath,
      vendorDir: command.vendorDir,
      packageIdentities: packageIdentities,
      binaryArtifactStore: command.binaryArtifactStore,
      binaryArtifactFallback: command.binaryArtifactFallback,
      attemptState: attemptState,
      packageLocalArtifactJunctionCapability:
          command.packageLocalArtifactJunctionCapability,
    );
    await binaryRecovery.resolveWithFinalBinaryRecovery(
      resolve: resolveWithRetries,
      recover: recover,
    );
    final changed =
        await checkout.materializeCheckoutSymlinks(command.scratchPath) |
        await normalizeResolvedPackageManifests(command.scratchPath);
    if (changed) {
      await binaryRecovery.resolveWithFinalBinaryRecovery(
        resolve: resolveWithRetries,
        recover: recover,
      );
    }
  }

  Future<bool> normalizeResolvedPackageManifests(String scratchPath) async {
    final checkouts = fileSystem.directory(p.join(scratchPath, 'checkouts'));
    var changed = false;
    if (checkouts.existsSync()) {
      for (final checkout in checkouts.listSync(followLinks: false)) {
        if (checkout is Directory) {
          changed =
              await manifestNormalizer.normalizeVendoredPackageManifests(
                checkout.path,
                consumedProducts: const {},
              ) ||
              changed;
        }
      }
    }
    return changed;
  }

  @override
  Future<void> materializeClone(
    String destination,
    String git,
    String vendorDir,
  ) async {
    await checkout.materializeGitCheckoutSymlinks(
      destination,
      git: git,
      stampDir: p.join(vendorDir, '.xcross-symlinks'),
    );
  }

  @override
  Future<({Map<String, String> pins, Map<String, String> originals})>
  bootstrapPinned(SwiftPmPinnedDependencyCommand command) =>
      pinnedResolver.resolve(command.packageDirectories, command.vendorDir);
  @override
  Future<void> prepareArtifacts(
    String packageRoot,
    String store,
    String fallback, {
    required bool capability,
  }) => binaryPreparation.prepareSupportedBinaryArtifacts(
    packageRoot: packageRoot,
    binaryArtifactStore: store,
    binaryArtifactFallback: fallback,
    packageLocalArtifactJunctionCapability: capability,
  );
  @override
  Future<bool> recoverArtifacts(
    SwiftPmDependencyArtifactCommand command,
  ) async {
    final provenance = await binaryProvenance.binaryArtifactProvenance(
      command.packageRoot,
      command.scratchPath,
      command.dependencies,
    );
    final normalized = await normalizeResolvedPackageManifests(
      command.scratchPath,
    );
    final archive = await binaryRecovery.recoverBootstrapBinaryArtifacts(
      scratchPath: command.scratchPath,
      binaryArtifactStore: command.store,
      provenance: provenance,
      attemptState: command.state,
      swiftPmArtifactJunctionCapability: command.capability,
    );
    final extraction = await extractedArtifacts.stageExtractedBinaryArtifacts(
      scratchPath: command.scratchPath,
      vendorDir: p.join(command.scratchPath, '.xcross-vendor'),
      binaryArtifactStore: command.store,
      binaryArtifactFallback: command.fallback,
      attemptState: command.state,
    );
    return normalized || archive || extraction;
  }
}
