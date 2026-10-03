import 'package:xcross/src/shared/flutter/swiftpm/build_session.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'dart:async';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmBuildDriver<T extends PlatformHostInterface> {
  SwiftPmBuildDriver({required this.binaryRecovery,required this.buildPlan,required this.hostPolicy,required this.interopRepair,required this.processPolicy,required this.runner,required this.sdkIdentity,required this.sdkRepository,required this.sourceRepair,required this.target,required this.targetPolicy,required this.toolchain,required this.toolchainResolver,required this.tools,required this.buildExecution,required this.dependencyPreparation,required this.checkout,required this.packageMetadata});
  final SwiftPmBinaryRecovery<T> binaryRecovery;
  final SwiftPmBuildPlan<T> buildPlan;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmInteropRepair<T> interopRepair;
  final SwiftPmProcessPolicy<T> processPolicy;
  final ProcessRunner<T> runner;
  final SwiftPmSdkIdentity sdkIdentity;
  final DarwinSdkRepository<T> sdkRepository;
  final SwiftPmSourceRepair<T> sourceRepair;
  final IosTarget<T> target;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  final SwiftPmToolchain<T> toolchain;
  final DarwinToolchainResolver<T> toolchainResolver;
  final AppleToolShimResolver<T> tools;
final SwiftPmBuildExecution<T> buildExecution;
final SwiftPmDependencyPreparation<T> dependencyPreparation;
final SwiftPmCheckout<T> checkout;
final SwiftPmPackageMetadata packageMetadata;

  /// Cross-compiles the synthesized packages in [pluginsDir] with

  /// `swift build --swift-sdk arm64-apple-ios`.
  Future<void> runSwiftBuild({
    required SwiftPmWorkspace workspace,
    required String pluginsDir,
    required String scratchPath,
    required String flutterXcframework,
    required IosDeploymentTarget deploymentTarget,
    required Set<String> interopTargetCandidates,
    required Map<String, Set<String>> interopConsumers,
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
  }) async {
    final outputDir = workspace.packages;
    final sdk = sdkRepository.current();
    if (sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run '
        '`xcross sdk install <Xcode.xip>` first.',
      );
    }
    // The bundle only compiles against the toolchain it was patched with,
    // so say so up front instead of letting Swift fail per source file with
    // hundreds of "this SDK is not supported by the compiler" errors.
    final mismatch = await sdkIdentity.hostToolchainMismatch(
      sdk.swiftSdkPath,
    );
    if (mismatch != null) {
      throw FlutterBuildError(sdkIdentity.mismatchGuidance(mismatch));
    }
    final swiftPackage = await runner.locateTool(
      hostPolicy.packageTool,
    );
    final swiftBuild = await runner.locateTool(
      hostPolicy.buildTool,
    );
    // Real `Flutter.framework` (not our FlutterFramework binary-target
    // wrapper). Our own aggregate target resolves `import Flutter` via
    // that wrapper's declared package dependency, but individual
    // third-party plugin targets often don't declare any such dependency
    // in their own Package.swift at all — they rely on Xcode's implicit,
    // project-wide framework search paths to make `import Flutter` resolve
    // (verified against a real published plugin: its manifest lists zero
    // dependencies, yet its Swift source does `import Flutter`). A plain
    // `swift build` has no such implicit project-wide behaviour, so we
    // reproduce it ourselves with build-wide framework search flags. Swift
    // targets need `-Xswiftc -F`; C and Objective-C targets need the matching
    // `-Xcc -F` pair so imports such as `<Flutter/Flutter.h>` resolve too.
    final flutterFrameworkSlice = targetPolicy.selectEngineSlice(
      flutterXcframework,
    );
    final linker = await toolchainResolver.resolveLd64Lld();
    final darwinClang = await hostPolicy.cCompiler(
      sdkRepository.iosSdk(sdk, target: target.buildPlatform),
      toolchainResolver,
    );
    final toolsetPath = await toolchain.writeToolset(
      outputDir: outputDir,
      linkerPath: linker,
      cCompilerPath: darwinClang,
      cxxCompilerPath: await hostPolicy.cxxCompiler(
        sdkRepository.iosSdk(sdk, target: target.buildPlatform),
        toolchainResolver,
      ),
    );
    // Apple's real `#Preview` macro plugin ships only inside Xcode, so no
    // cross host has it. The compiled stub answers the macro through
    // Swift's own `-load-plugin-executable` extension point instead — its
    // host compiler is whichever one built [darwinClang], available on
    // every host that can build this project at all.
    final hostCompiler = await tools.resolveHostCompiler(
      darwinClang ?? 'cc',
    );
    final previewMacroStub = await buildPlan.writePreviewMacroStub(
      outputDir: outputDir,
      cCompilerPath: hostCompiler.executable,
      cCompilerArguments: hostCompiler.arguments,
    );
    final objectiveCCompatibilityHeader = await buildPlan
        .writeObjectiveCCompatibilityHeader(outputDir);
    final swiftSdksPath = p.dirname(sdk.swiftSdkPath);
    final environment = processPolicy.swiftProcessEnvironment();
    await dependencyPreparation.prepare(
      SwiftPmDependencyPreparationRequest<T>(
        binaryRecovery:binaryRecovery,checkout:checkout,interopRepair:interopRepair,packageMetadata:packageMetadata,processPolicy:processPolicy,swiftSdkTriple:target.buildPlatform.swiftSdkTriple,
        swift: swiftPackage,
        pluginsDir: pluginsDir,

        scratchPath: scratchPath,
        swiftSdksPath: swiftSdksPath,
        toolsetPath: toolsetPath,
        vendorDir: workspace.vendor,
        binaryArtifactStore: workspace.binaryArtifactStore,
        binaryArtifactFallback: workspace.binaryArtifactFallback,
        swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
        packageLocalArtifactJunctionCapability:
            packageLocalArtifactJunctionCapability,
        environment: environment,
      ),
    );
    final baseArguments = buildPlan.swiftBuildArguments(
      pluginsDir: pluginsDir,
      scratchPath: scratchPath,
      swiftSdksPath: swiftSdksPath,
      iosSdk: sdkRepository.iosSdk(
        sdk,
        target: deploymentTarget.platform,
      ),
      swiftSdkTriple: deploymentTarget.swiftSdkTriple,
      flutterFrameworkSlice: flutterFrameworkSlice,
      objectiveCCompatibilityHeader: objectiveCCompatibilityHeader,
      toolsetPath: toolsetPath,
      linkerPath: linker,
      previewMacroStubPath: previewMacroStub,
    );

    await sourceRepair.buildTranslatingSdkMismatch(
      () => runner.runChecked(
        swiftBuild,
        [...baseArguments, '--print-manifest-job-graph'],
        environment: environment,
        label: 'swift build plan',
      ),
    );
    // Inspect the plan just emitted, not a directory from an earlier build.
    final targetBuildDir = SwiftPmBuildPlan.resolveTargetBuildDir(
      scratchPath,
      triple: deploymentTarget.swiftSdkTriple,
    );
    await hostPolicy.repairBuildPlan(scratchPath, targetBuildDir);
    final interopArguments = SwiftPmBuildPlan.plannedSwiftInteropSearchPaths(
      targetBuildDir,
    );
    // The first plan run could not carry [interopArguments], because the
    // paths it discovers are read out of the plan it produces. SwiftPM
    // records the resulting command lines in `debug.yaml` and llbuild
    // replays them verbatim, so without a second plan run every compile
    // would execute with the pre-interop arguments no matter what this
    // build passes. Re-planning rewrites the manifest with the search
    // paths applied.
    //
    // The rewrite only has to happen when the manifest does not already
    // carry the paths. Re-planning unconditionally costs a whole extra
    // `swift build` planning process (~13s on Windows for
    // examples/flutter_example) on every build including incremental ones,
    // to reproduce a manifest that is already byte-identical.
    if (interopArguments.isNotEmpty &&
        !SwiftPmBuildPlan.manifestCarriesInteropSearchPaths(
          scratchPath,
          interopArguments,
        )) {
      await sourceRepair.buildTranslatingSdkMismatch(
        () => runner.runChecked(
          swiftBuild,
          [...baseArguments, ...interopArguments, '--print-manifest-job-graph'],
          environment: environment,
          label: 'swift build plan (interop)',
        ),
      );
      await hostPolicy.repairBuildPlan(scratchPath, targetBuildDir);
    }
    final operation = SwiftPmBuildSession<T>(execution:buildExecution,command:SwiftPmBuildCommand(executable:swiftBuild,arguments:[...baseArguments,...interopArguments],environment:environment,scratchPath:scratchPath,targetBuildDir:targetBuildDir),sourceRepair:sourceRepair,interopRepair:interopRepair,ownedRoots:[workspace.vendor,p.join(outputDir,'Packages')],consumerProducts:interopConsumers);

    await sourceRepair.buildTranslatingSdkMismatch(
      () => interopRepair.buildWithInteropRecovery(
        operation:operation,
        targetBuildDir: targetBuildDir,
        interopTargetCandidates: interopTargetCandidates,
        skipInitialRecovery: true,

      ),
    );
  }
}
