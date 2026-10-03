import 'dart:async';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmBuildDriver<T extends PlatformHostInterface> {
  SwiftPmBuildDriver(this.runtime);
  final SwiftPmRuntime<T> runtime;

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
    final sdk = runtime.sdkRepository.current();
    if (sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run '
        '`xcross sdk install <Xcode.xip>` first.',
      );
    }
    // The bundle only compiles against the toolchain it was patched with,
    // so say so up front instead of letting Swift fail per source file with
    // hundreds of "this SDK is not supported by the compiler" errors.
    final mismatch = await runtime.sdkIdentity.hostToolchainMismatch(
      sdk.swiftSdkPath,
    );
    if (mismatch != null) {
      throw FlutterBuildError(runtime.sdkIdentity.mismatchGuidance(mismatch));
    }
    final swiftPackage = await runtime.runner.locateTool(
      runtime.hostPolicy.packageTool,
    );
    final swiftBuild = await runtime.runner.locateTool(
      runtime.hostPolicy.buildTool,
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
    final flutterFrameworkSlice = runtime.targetPolicy.selectEngineSlice(
      flutterXcframework,
    );
    final linker = await runtime.toolchainResolver.resolveLd64Lld();
    final darwinClang = await runtime.hostPolicy.cCompiler(
      runtime.sdkRepository.iosSdk(sdk, target: runtime.target.buildPlatform),
      runtime.toolchainResolver,
    );
    final toolsetPath = await runtime.toolchain.writeToolset(
      outputDir: outputDir,
      linkerPath: linker,
      cCompilerPath: darwinClang,
      cxxCompilerPath: await runtime.hostPolicy.cxxCompiler(
        runtime.sdkRepository.iosSdk(sdk, target: runtime.target.buildPlatform),
        runtime.toolchainResolver,
      ),
    );
    // Apple's real `#Preview` macro plugin ships only inside Xcode, so no
    // cross host has it. The compiled stub answers the macro through
    // Swift's own `-load-plugin-executable` extension point instead — its
    // host compiler is whichever one built [darwinClang], available on
    // every host that can build this project at all.
    final hostCompiler = await runtime.tools.resolveHostCompiler(
      darwinClang ?? 'cc',
    );
    final previewMacroStub = await runtime.buildPlan.writePreviewMacroStub(
      outputDir: outputDir,
      cCompilerPath: hostCompiler.executable,
      cCompilerArguments: hostCompiler.arguments,
    );
    final objectiveCCompatibilityHeader = await runtime.buildPlan
        .writeObjectiveCCompatibilityHeader(outputDir);
    final swiftSdksPath = p.dirname(sdk.swiftSdkPath);
    final environment = runtime.processPolicy.swiftProcessEnvironment();
    await runtime.hostPolicy.resolveDependencies(
      () => runtime.binaryRecovery.prepareWindowsDependencyGraph(
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
    final baseArguments = runtime.buildPlan.swiftBuildArguments(
      pluginsDir: pluginsDir,
      scratchPath: scratchPath,
      swiftSdksPath: swiftSdksPath,
      iosSdk: runtime.sdkRepository.iosSdk(
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

    await runtime.sourceRepair.buildTranslatingSdkMismatch(
      () => runtime.runner.runChecked(
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
    await runtime.hostPolicy.repairBuildPlan(scratchPath, targetBuildDir);
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
      await runtime.sourceRepair.buildTranslatingSdkMismatch(
        () => runtime.runner.runChecked(
          swiftBuild,
          [...baseArguments, ...interopArguments, '--print-manifest-job-graph'],
          environment: environment,
          label: 'swift build plan (interop)',
        ),
      );
      await runtime.hostPolicy.repairBuildPlan(scratchPath, targetBuildDir);
    }
    Future<void> runBuild([List<String> selection = const []]) async {
      final arguments = <String>[
        ...baseArguments,
        ...interopArguments,
        ...selection,
      ];

      Future<void> invoke() => runtime.runner.runChecked(
        swiftBuild,
        arguments,
        environment: environment,
        captureAndEcho: runtime.hostPolicy.captureBuildOutput,
        label: 'swift build',
      );

      await runtime.hostPolicy.repairBuildPlan(scratchPath, targetBuildDir);
      await runtime.sourceRepair.buildWithSwiftUIStateRecovery(
        ownedRoots: [workspace.vendor, p.join(outputDir, 'Packages')],
        build: () =>
            runtime.hostPolicy.invokeBuild(invoke, scratchPath, targetBuildDir),
      );
    }

    await runtime.sourceRepair.buildTranslatingSdkMismatch(
      () => runtime.interopRepair.buildWithInteropRecovery(
        build: runBuild,
        buildTarget: (target) => runBuild(['--target', target]),
        targetBuildDir: targetBuildDir,
        interopTargetCandidates: interopTargetCandidates,
        skipInitialRecovery: true,
        repairConsumers: () =>
            runtime.interopRepair.repairSwiftInteropConsumers(
              targetBuildDir: targetBuildDir,
              consumerProducts: interopConsumers,
            ),
      ),
    );
  }
}
