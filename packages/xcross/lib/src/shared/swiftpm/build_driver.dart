import 'dart:async';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/swiftpm/apple_tool_shims.dart';
import 'package:xcross/src/shared/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/swiftpm/build_session.dart';
import 'package:xcross/src/shared/swiftpm/checkout.dart';
import 'package:xcross/src/shared/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/swiftpm/errors.dart';
import 'package:xcross/src/shared/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/swiftpm/interop_build_recovery.dart';
import 'package:xcross/src/shared/swiftpm/interop_consumer_repair.dart';
import 'package:xcross/src/shared/swiftpm/ios_deployment_target.dart';
import 'package:xcross/src/shared/swiftpm/manifest_target_alias.dart';
import 'package:xcross/src/shared/swiftpm/module_warmup.dart';
import 'package:xcross/src/shared/swiftpm/plan_reader.dart';
import 'package:xcross/src/shared/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/swiftpm/source_repair.dart';
import 'package:xcross/src/shared/swiftpm/swiftpm_workspace.dart';
import 'package:xcross/src/shared/swiftpm/toolchain.dart';
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';

@internal
typedef SwiftPmDependencyReconciler =
    Future<Map<String, Set<String>>?> Function(
      String scratchPath,
      Map<String, Set<String>> consumedProducts,
    );

@internal
final class SwiftPmBuildDriver<T extends PlatformHostInterface> {
  SwiftPmBuildDriver({
    required this.buildPlan,
    required this.hostPolicy,
    required this.hostBuildServices,
    required this.consumerRepair,
    required this.planReader,
    required this.processPolicy,
    required this.runner,
    required this.sdkIdentity,
    required this.sdkRepository,
    required this.sourceRepair,
    required this.target,
    required this.targetPolicy,
    required this.toolchain,
    required this.toolchainResolver,
    required this.tools,
    required this.buildExecution,
    required this.dependencyPreparation,
    required this.checkout,
  });
  final SwiftPmBuildPlan<T> buildPlan;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmHostBuildServices<T> hostBuildServices;
  final SwiftPmInteropConsumerRepair<T> consumerRepair;
  final SwiftPmPlanReader planReader;
  final SwiftPmProcessPolicy<T> processPolicy;
  final ProcessRunner<T> runner;
  final SwiftPmSdkIdentity sdkIdentity;
  final DarwinSdkRepository<T> sdkRepository;
  final SwiftPmSourceRepair<T> sourceRepair;
  final IosTarget<T> target;
  final SwiftPmTargetPolicy<T> targetPolicy;
  final SwiftPmToolchain<T> toolchain;
  final DarwinToolchainResolver<T> toolchainResolver;
  final AppleToolShimResolver<T> tools;
  final SwiftPmBuildExecution<T> buildExecution;
  final SwiftPmDependencyPreparation<T> dependencyPreparation;
  final SwiftPmCheckout<T> checkout;

  /// Cross-compiles the synthesized packages in [pluginsDir] with

  /// `swift build --swift-sdk arm64-apple-ios`.
  Future<void> runSwiftBuild({
    required SwiftPmWorkspace workspace,
    required String pluginsDir,
    required String scratchPath,
    required String productName,
    required List<String> frameworkSearchPaths,
    required IosDeploymentTarget deploymentTarget,
    required Set<String> interopTargetCandidates,
    required Map<String, Set<String>> interopConsumers,
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
    Map<String, Set<String>> consumedProducts = const {},
    SwiftPmDependencyReconciler? reconcileDependencies,
  }) async {
    final outputDir = workspace.packages;
    final sdk = await _requireCompatibleSdk();
    final swiftPackage = await runner.locateTool(hostPolicy.packageTool);
    final swiftBuild = await runner.locateTool(hostPolicy.buildTool);
    // Callers pass build-wide framework search paths here. Individual
    // third-party package targets may import frameworks they never declare
    // in their own Package.swift, relying on Xcode's implicit, project-wide
    // framework search paths. A plain `swift build` has no such implicit
    // behaviour, so it is reproduced with build-wide framework search flags:
    // Swift targets need `-Xswiftc -F`; C and Objective-C targets need the
    // matching `-Xcc -F` pair.
    final linker = await toolchainResolver.resolveLd64Lld();
    final darwinClang = await hostBuildServices.cCompiler(
      sdkRepository.iosSdk(sdk, target: target.buildPlatform),
    );
    final toolsetPath = await toolchain.writeToolset(
      outputDir: outputDir,
      linkerPath: linker,
      cCompilerPath: darwinClang,
      cxxCompilerPath: await hostBuildServices.cxxCompiler(
        sdkRepository.iosSdk(sdk, target: target.buildPlatform),
      ),
    );
    final objectiveCCompatibilityHeader = await buildPlan
        .writeObjectiveCCompatibilityHeader(outputDir);
    final swiftSdksPath = p.dirname(sdk.swiftSdkPath);
    final initialEnvironment = await processPolicy.swiftProcessEnvironment(
      consumedProducts: consumedProducts,
    );
    final macroServerArguments = await buildPlan.macroServerArguments(
      cacheRoot: workspace.cacheRoot,
      swiftBuild: swiftBuild,
      environment: initialEnvironment,
    );
    SwiftPmDependencyCommand dependencyCommand(
      Map<String, String> environment,
    ) => SwiftPmDependencyCommand(
      swiftSdkTriple: target.buildPlatform.swiftSdkTriple,
      swift: swiftPackage,
      pluginsDir: pluginsDir,
      scratchPath: scratchPath,
      swiftSdksPath: swiftSdksPath,
      toolsetPath: toolsetPath,
      binaryArtifactStore: workspace.binaryArtifactStore,
      binaryArtifactFallback: workspace.binaryArtifactFallback,
      swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
      packageLocalArtifactJunctionCapability:
          packageLocalArtifactJunctionCapability,
      environment: environment,
    );
    final environment = await _resolveDependencies(
      dependencyCommand,
      scratchPath: scratchPath,
      consumedProducts: consumedProducts,
      environment: initialEnvironment,
      reconcileDependencies: reconcileDependencies,
    );
    final iosSdk = sdkRepository.iosSdk(sdk, target: deploymentTarget.platform);
    if (hostPolicy.warmsImplicitModules) {
      await _refreshModuleWarmup(
        pluginsDir: pluginsDir,
        packagesDir: p.join(outputDir, 'Packages'),
        scratchPath: scratchPath,
        iosSdk: iosSdk,
      );
    }
    final baseArguments = buildPlan.swiftBuildArguments(
      pluginsDir: pluginsDir,
      scratchPath: scratchPath,
      swiftSdksPath: swiftSdksPath,
      iosSdk: iosSdk,
      swiftSdkTriple: deploymentTarget.swiftSdkTriple,
      frameworkSearchPaths: frameworkSearchPaths,
      objectiveCCompatibilityHeader: objectiveCCompatibilityHeader,
      toolsetPath: toolsetPath,
      linkerPath: linker,
      macroServerArguments: macroServerArguments,
    );

    final (:targetBuildDir, :interopArguments) = await _planBuild(
      swiftBuild: swiftBuild,
      baseArguments: baseArguments,
      environment: environment,
      scratchPath: scratchPath,
      deploymentTarget: deploymentTarget,
    );
    final command = SwiftPmBuildCommand(
      executable: swiftBuild,
      arguments: [...baseArguments, ...interopArguments],
      environment: environment,
      scratchPath: scratchPath,
      targetBuildDir: targetBuildDir,
      consumerProducts: interopConsumers,
    );
    if (hostPolicy.warmsImplicitModules) await _warmImplicitModules(command);
    final operation = SwiftPmBuildSession<T>(
      execution: buildExecution,
      command: command,
      consumerRepair: consumerRepair,
      targetAlias: SwiftPmManifestTargetAlias(
        fileSystem: planReader.fileSystem,
        productName: productName,
      ),
    );

    await sourceRepair.buildTranslatingSdkMismatch(
      () =>
          SwiftPmInteropBuildRecovery<T>(
            session: operation,
            planReader: planReader,
            consumerRepair: consumerRepair,
            hostPolicy: hostPolicy,
            execution: buildExecution,
          ).build(
            targetBuildDir: targetBuildDir,
            interopTargetCandidates: interopTargetCandidates,
            productName: productName,
            skipInitialRecovery: true,
          ),
    );
  }

  /// Points the warm-up target at every SDK module the resolved plugin graph
  /// imports. Runs after resolution, so the checkouts exist to be scanned.
  Future<void> _refreshModuleWarmup({
    required String pluginsDir,
    required String packagesDir,
    required String scratchPath,
    required String iosSdk,
  }) async {
    final modules = await SwiftPmModuleWarmup(fileSystem: planReader.fileSystem)
        .refresh(
          pluginsDir: pluginsDir,
          roots: [packagesDir, p.join(scratchPath, 'checkouts')],
          iosSdk: iosSdk,
          write: buildPlan.filesystem.writeStable,
        );
    runner.log.logTrace(
      '[module warm-up] ${modules.length} SDK modules: ${modules.join(', ')}',
    );
  }

  /// Builds the warm-up target alone, so the SDK's implicit Clang modules are
  /// compiled by one process before the parallel build reads them (see
  /// [SwiftPmModuleWarmup]).
  ///
  /// Only an optimisation: on failure the parallel build still runs and
  /// builds whatever modules are missing itself, as it did before.
  Future<void> _warmImplicitModules(SwiftPmBuildCommand command) async {
    try {
      await buildExecution.execute(
        SwiftPmBuildCommand(
          executable: command.executable,
          arguments: [...command.arguments, '--target', moduleWarmupTargetName],
          environment: command.environment,
          scratchPath: command.scratchPath,
          targetBuildDir: command.targetBuildDir,
          consumerProducts: command.consumerProducts,
        ),
      );
    } on Object catch (error) {
      runner.log.logTrace(
        '[module warm-up] failed, continuing without it: $error',
      );
    }
  }

  Future<DarwinSdk> _requireCompatibleSdk() async {
    final sdk = sdkRepository.current();
    if (sdk == null) {
      throw SwiftPmError(
        'Darwin Swift SDK not found. Run '
        '`xcross sdk install <Xcode.xip>` first.',
      );
    }
    // The bundle only compiles against the toolchain it was patched with,
    // so say so up front instead of letting Swift fail per source file with
    // hundreds of "this SDK is not supported by the compiler" errors.
    final mismatch = await sdkIdentity.hostToolchainMismatch(sdk.swiftSdkPath);
    if (mismatch != null) {
      throw SwiftPmError(sdkIdentity.mismatchGuidance(mismatch));
    }
    return sdk;
  }

  Future<Map<String, String>> _resolveDependencies(
    SwiftPmDependencyCommand Function(Map<String, String> environment)
    dependencyCommand, {
    required String scratchPath,
    required Map<String, Set<String>> consumedProducts,
    required Map<String, String> environment,
    required SwiftPmDependencyReconciler? reconcileDependencies,
  }) async {
    var consumed = consumedProducts;
    var current = environment;
    await dependencyPreparation.prepare(dependencyCommand(current));
    while (true) {
      final updated = await reconcileDependencies?.call(scratchPath, consumed);
      if (updated == null) break;
      consumed = updated;
      current = await processPolicy.swiftProcessEnvironment(
        consumedProducts: consumed,
      );
      await dependencyPreparation.prepare(dependencyCommand(current));
    }
    return current;
  }

  Future<({String targetBuildDir, List<String> interopArguments})> _planBuild({
    required String swiftBuild,
    required List<String> baseArguments,
    required Map<String, String> environment,
    required String scratchPath,
    required IosDeploymentTarget deploymentTarget,
  }) async {
    await sourceRepair.buildTranslatingSdkMismatch(
      () => buildPlan.recordPlan(
        swiftBuild,
        baseArguments,
        environment: environment,
        label: 'swift build plan',
      ),
    );
    // Inspect the plan just emitted, not a directory from an earlier build.
    final targetBuildDir = planReader.resolveTargetBuildDir(
      scratchPath,
      triple: deploymentTarget.swiftSdkTriple,
    );
    await hostPolicy.repairBuildPlan(scratchPath, targetBuildDir);
    final interopArguments = planReader.plannedSwiftInteropSearchPaths(
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
    final needsInteropReplan =
        interopArguments.isNotEmpty &&
        !planReader.manifestCarriesInteropSearchPaths(
          scratchPath,
          interopArguments,
        );
    if (needsInteropReplan) {
      await sourceRepair.buildTranslatingSdkMismatch(
        () => buildPlan.recordPlan(
          swiftBuild,
          [...baseArguments, ...interopArguments],
          environment: environment,
          label: 'swift build plan (interop)',
        ),
      );
      await hostPolicy.repairBuildPlan(scratchPath, targetBuildDir);
    }
    return (targetBuildDir: targetBuildDir, interopArguments: interopArguments);
  }
}
