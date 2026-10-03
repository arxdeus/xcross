import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_git_repository.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
abstract interface class SwiftPmDependencyPreparation<T extends PlatformHostInterface> {
Future<void> prepare(SwiftPmDependencyPreparationRequest<T> request);
Future<void> materializeClone(SwiftPmCheckout<T> checkout,String destination,String git,String vendorDir);
Future<({Map<String,String> pins,Map<String,String> originals})> bootstrapPinned(SwiftPmPinnedDependencyRequest<T> request);
Future<void> prepareArtifacts(SwiftPmBinaryRecovery<T> recovery,String packageRoot,String store,String fallback,bool capability);
Future<bool> recoverArtifacts(SwiftPmDependencyArtifactRecoveryRequest<T> request);

}
final class SwiftPmDependencyPreparationRequest<T extends PlatformHostInterface> {
SwiftPmDependencyPreparationRequest({required this.swift,required this.pluginsDir,required this.scratchPath,required this.swiftSdksPath,required this.toolsetPath,required this.vendorDir,required this.binaryArtifactStore,required this.binaryArtifactFallback,required this.swiftPmArtifactJunctionCapability,required this.packageLocalArtifactJunctionCapability,required this.environment,required this.swiftSdkTriple,required this.binaryRecovery,required this.checkout,required this.interopRepair,required this.packageMetadata,required this.processPolicy});
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
final Map<String,String>? environment;
final String swiftSdkTriple;
final SwiftPmBinaryRecovery<T> binaryRecovery;
final SwiftPmCheckout<T> checkout;
final SwiftPmInteropRepair<T> interopRepair;
final SwiftPmPackageMetadata packageMetadata;
final SwiftPmProcessPolicy<T> processPolicy;
}

final class SwiftPmPinnedDependencyRequest<T extends PlatformHostInterface> {
SwiftPmPinnedDependencyRequest({required this.packageDirectories,required this.vendorDir,required this.runner,required this.fileSystem,required this.filesystem,required this.repository,required this.manifestNormalizer,this.clonePackage});
final Iterable<String> packageDirectories;
final String vendorDir;
final ProcessRunner<T> runner;
final SwiftPmArtifactFileSystem fileSystem;
final SwiftPmFilesystem<T> filesystem;
final SwiftPmGitRepository<T> repository;
final SwiftPmCheckoutManifestNormalizer<T> manifestNormalizer;
final Future<void> Function(String,String,String,String)? clonePackage;
}

final class SwiftPmDependencyArtifactRecoveryRequest<T extends PlatformHostInterface> {
SwiftPmDependencyArtifactRecoveryRequest({required this.recovery,required this.interopRepair,required this.packageRoot,required this.scratchPath,required this.store,required this.fallback,required this.dependencies,required this.state,required this.capability});
final SwiftPmBinaryRecovery<T> recovery;
final SwiftPmInteropRepair<T> interopRepair;
final String packageRoot;
final String scratchPath;
final String store;
final String fallback;
final List<SwiftPmPackageDependency> dependencies;
final SwiftPmBinaryAttemptState state;
final bool capability;
}
