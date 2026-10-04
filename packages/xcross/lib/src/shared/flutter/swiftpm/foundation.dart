import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_layout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/extracted_artifact_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_consumer_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/librarian_resolver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/network_retry.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plan_reader.dart';
import 'package:xcross/src/shared/flutter/swiftpm/preview_macro_compiler.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
final class SwiftPmFoundation<T extends PlatformHostInterface> {
  final SwiftPmHostBuildServices<T> hostBuildServices;
  final SwiftPmLibrarianResolver<T> librarianResolver;
  final SwiftPmGateExecution<T> gateExecution;
  SwiftPmFoundation({
    required this.hostBuildServices,
    required this.librarianResolver,
    required this.gateExecution,
    required this.targetPolicy,
    required this.runner,
    required this.sdkRepository,
    required this.toolchainResolver,
    required this.tools,
    required this.hostPolicy,
    required this.artifactFileSystem,
    required this.sdkIdentity,
    required this.publicationCoordinator,
    required this.transport,
    required this.copyPolicy,
    required this.checkoutAttributes,
    required this.filesystem,
    required this.processPolicy,
    required this.sourceRepair,
    required this.toolchain,
    required this.previewCompiler,
    required this.planReader,
    required this.buildPlan,
    required this.consumerRepair,
    required this.networkRetry,
    required this.binaryLayout,
    required this.binaryProvenance,
    required this.binaryPreparation,
    required this.binaryRecovery,
    required this.extractedArtifacts,
    required this.packageMetadata,
  });
  final FlutterTargetBuildPolicy<T> targetPolicy;
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> sdkRepository;
  final DarwinToolchainResolver<T> toolchainResolver;
  final AppleToolShimResolver<T> tools;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmSdkIdentity sdkIdentity;
  final SwiftPmPublicationCoordinator publicationCoordinator;
  final SwiftPmArchiveTransport transport;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  final SwiftPmCheckoutAttributes checkoutAttributes;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmProcessPolicy<T> processPolicy;
  final SwiftPmSourceRepair<T> sourceRepair;
  final SwiftPmToolchain<T> toolchain;
  final SwiftPmPreviewMacroCompiler<T> previewCompiler;
  final SwiftPmPlanReader planReader;
  final SwiftPmBuildPlan<T> buildPlan;
  final SwiftPmInteropConsumerRepair<T> consumerRepair;
  final SwiftPmNetworkRetry<T> networkRetry;
  final SwiftPmBinaryLayout<T> binaryLayout;
  final SwiftPmBinaryProvenance<T> binaryProvenance;
  final SwiftPmBinaryPreparation<T> binaryPreparation;
  final SwiftPmBinaryRecovery<T> binaryRecovery;
  final SwiftPmExtractedArtifactRecovery<T> extractedArtifacts;
  final SwiftPmPackageMetadata packageMetadata;
}
