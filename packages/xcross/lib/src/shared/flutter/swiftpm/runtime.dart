import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_capabilities.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/assembly.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_driver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_links.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_vendor.dart';
import 'package:xcross/src/shared/flutter/swiftpm/discovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/module_files.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plugin_overlay.dart';
import 'package:xcross/src/shared/flutter/swiftpm/preview_macro_compiler.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';
import 'package:xcross/src/shared/flutter/swiftpm/workspace_stager.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

final class SwiftPmRuntime<T extends PlatformHostInterface> {
  SwiftPmRuntime(
    this.targetPolicy,
    this.runner,
    this.sdkRepository,
    this.toolchainResolver,
    this.tools,
    this.hostPolicy,
    this.artifactFileSystem,
    this.sdkIdentity,
    this.publicationCoordinator,
    this.transport,
    this.copyPolicy,
    this.buildExecution,
    this.dependencyPreparation,
    this.checkout,
    this.checkoutAttributes,
    this.checkoutManifestNormalizer,
  );
  IosTarget<T> get target => targetPolicy.target;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  T get host => target.host;

  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> sdkRepository;
  final DarwinToolchainResolver<T> toolchainResolver;
  final AppleToolShimResolver<T> tools;
  late final symlinks = HostSymlinkCapability(host);
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmSdkIdentity sdkIdentity;
  final SwiftPmPublicationCoordinator publicationCoordinator;
  final SwiftPmArchiveTransport transport;
  final SwiftPmArtifactCopyPolicy copyPolicy;
final SwiftPmBuildExecution<T> buildExecution;
final SwiftPmDependencyPreparation<T> dependencyPreparation;
  bool? get sourceFallbackOverride => processPolicy.sourceFallbackOverride;
  set sourceFallbackOverride(bool? value) => processPolicy.sourceFallbackOverride=value;
  late final gateExecution=SwiftPmGateExecution<T>(runner:runner,sdkRepository:sdkRepository,toolchain:toolchain,processPolicy:processPolicy,buildPlan:buildPlan,target:target,artifactFileSystem:artifactFileSystem);
  late final artifactCapabilities = SwiftPmArtifactCapabilities<T>(paths:host.paths,fileSystem:artifactFileSystem,execution:gateExecution,platform:hostPolicy.gatePlatform,identities:SwiftPmArtifactIdentityResolver<T>(repository:sdkRepository,sdkIdentity:sdkIdentity,hostPolicy:hostPolicy,toolchain:toolchain));
  late final pluginOverlay = SwiftPmPluginOverlay<T>(binaryRecovery:binaryRecovery,dependencyVendor:dependencyVendor,filesystem:filesystem,sourceNormalizer:sourceNormalizer);
  late final workspaceStager = SwiftPmWorkspaceStager<T>(artifactFileSystem:artifactFileSystem,binaryRecovery:binaryRecovery,checkout:checkout,checkoutManifestNormalizer:checkoutManifestNormalizer,dependencyPreparation:dependencyPreparation,filesystem:filesystem,hostPolicy:hostPolicy,manifest:manifest,pluginOverlay:pluginOverlay,runner:runner,sourceNormalizer:sourceNormalizer);
  late final buildDriver = SwiftPmBuildDriver<T>(binaryRecovery:binaryRecovery,buildPlan:buildPlan,hostPolicy:hostPolicy,interopRepair:interopRepair,processPolicy:processPolicy,runner:runner,sdkIdentity:sdkIdentity,sdkRepository:sdkRepository,sourceRepair:sourceRepair,target:target,targetPolicy:targetPolicy,toolchain:toolchain,toolchainResolver:toolchainResolver,tools:tools,buildExecution:buildExecution,dependencyPreparation:dependencyPreparation,checkout:checkout,packageMetadata:packageMetadata);

  late final discovery = SwiftPmDiscovery<T>(hostPolicy: hostPolicy,sdkIdentity: sdkIdentity,sdkRepository: sdkRepository,toolchain: toolchain);
  late final assembly = SwiftPmAssembly<T>(hostPolicy: hostPolicy);
  final SwiftPmCheckout<T> checkout;
final SwiftPmCheckoutAttributes checkoutAttributes;
final SwiftPmCheckoutManifestNormalizer<T> checkoutManifestNormalizer;
  late final interopRepair = SwiftPmInteropRepair<T>(buildPlan:buildPlan,checkoutManifestNormalizer:checkoutManifestNormalizer,filesystem:filesystem,hostPolicy:hostPolicy,buildExecution:buildExecution);
  late final sourceNormalizer = SwiftPmHostSourceNormalizer(fileSystem: artifactFileSystem);
  late final moduleFiles = SwiftPmModuleFiles(fileSystem: artifactFileSystem);
  late final packageMetadata = SwiftPmPackageMetadata(fileSystem: artifactFileSystem);
  late final manifest = SwiftPmManifest<T>(targetPolicy: targetPolicy);
  late final sourceRepair = SwiftPmSourceRepair<T>(filesystem: filesystem,hostPolicy: hostPolicy,processPolicy: processPolicy,runner: runner,sdkIdentity: sdkIdentity);
  late final sourceFallback = SwiftPmSourceFallback<T>(filesystem: filesystem,moduleFiles: moduleFiles);
  late final dependencyVendor = SwiftPmDependencyVendor<T>(binaryRecovery:binaryRecovery,checkout:checkout,checkoutManifestNormalizer:checkoutManifestNormalizer,dependencyPreparation:dependencyPreparation,runner:runner);
  late final filesystem = SwiftPmFilesystem<T>(host: host,runner: runner,artifactFileSystem: artifactFileSystem);
  late final toolchain = SwiftPmToolchain<T>(filesystem: filesystem,hostPolicy: hostPolicy,runner: runner,sdkIdentity: sdkIdentity,sdkRepository: sdkRepository,target: target,toolchainResolver: toolchainResolver);
  late final binaryRecovery = SwiftPmBinaryRecovery<T>(artifactFileSystem:artifactFileSystem,checkoutAttributes:checkoutAttributes,copyPolicy:copyPolicy,dependencyPreparation:dependencyPreparation,filesystem:filesystem,host:host,hostPolicy:hostPolicy,interopRepair:interopRepair,publicationCoordinator:publicationCoordinator,runner:runner,sourceRepair:sourceRepair,targetPolicy:targetPolicy,transport:transport);
  late final previewCompiler = SwiftPmPreviewMacroCompiler<T>(host:host,filesystem:filesystem,compiler:ProcessSwiftPmNativeCompiler<T>(runner));
  late final buildPlan = SwiftPmBuildPlan<T>(filesystem: filesystem,hostPolicy: hostPolicy,runner: runner,previewCompiler:previewCompiler);
  late final processPolicy = SwiftPmProcessPolicy<T>(host: host,hostPolicy: hostPolicy,runner: runner,tools: tools);

}
