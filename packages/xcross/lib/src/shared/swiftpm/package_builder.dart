import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/swiftpm/build_driver.dart';
import 'package:xcross/src/shared/swiftpm/ios_deployment_target.dart';
import 'package:xcross/src/shared/swiftpm/package_types.dart';
import 'package:xcross/src/shared/swiftpm/runtime.dart';
import 'package:xcross/src/shared/swiftpm/swiftpm_workspace.dart';
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';

/// Builds one aggregate Swift package for an iOS target and assembles its
/// products.
///
/// The caller stages the packages and writes the aggregate `Package.swift`
/// (declaring a `.dynamic` library product named `productName`) into a
/// directory under [SwiftPmWorkspace.packages]. This then resolves and
/// cross-compiles it with `swift build`, and collects the dylibs, dynamic
/// frameworks, resource bundles and Swift modules it produced.
///
/// Flutter's generated plugins package and Compose's SwiftUI host packages
/// both build through here.
@internal
final class SwiftPmPackageBuilder<T extends PlatformHostInterface> {
  SwiftPmPackageBuilder(this.engine);

  /// The configured SwiftPM services for [policy].
  final SwiftPmRuntime<T> engine;

  SwiftPmTargetPolicy<T> get policy => engine.targetPolicy;

  /// The stable per-project workspace (`~/.cache/xcross/swiftpm/<hash>`, or
  /// under `XCROSS_CACHE_DIR`) for [projectRoot] on this target.
  SwiftPmWorkspace workspaceFor(
    String projectRoot, {
    Map<String, String>? environment,
  }) => SwiftPmWorkspace.forProject(
    projectRoot,
    policy: policy,
    environment: environment,
  );

  /// SwiftPM's debug output directory for [deploymentTarget] in [workspace].
  String targetDebugDirectory(
    SwiftPmWorkspace workspace,
    IosDeploymentTarget deploymentTarget,
  ) => p.join(workspace.scratch, deploymentTarget.swiftSdkTriple, 'debug');

  /// Resolves and builds the package in [packageDir], then assembles the
  /// products of [productName].
  ///
  /// [frameworkSearchPaths] are passed to every Swift and C target as
  /// `-F`, reproducing Xcode's project-wide framework search paths.
  /// [packageIdentities] maps staged SwiftPM identities to the ones Xcode
  /// would use, for resource bundle identifiers.
  Future<SwiftPmBuildResult> build({
    required SwiftPmWorkspace workspace,
    required String packageDir,
    required String productName,
    required IosDeploymentTarget deploymentTarget,
    List<String> frameworkSearchPaths = const [],
    Set<String> interopTargetCandidates = const {},
    Map<String, Set<String>> interopConsumers = const {},
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
    Map<String, Set<String>> consumedProducts = const {},
    SwiftPmDependencyReconciler? reconcileDependencies,
    Map<String, String> packageIdentities = const {},
  }) async {
    await engine.buildDriver.runSwiftBuild(
      workspace: workspace,
      pluginsDir: packageDir,
      scratchPath: workspace.scratch,
      productName: productName,
      frameworkSearchPaths: frameworkSearchPaths,
      deploymentTarget: deploymentTarget,
      interopTargetCandidates: interopTargetCandidates,
      interopConsumers: interopConsumers,
      swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
      packageLocalArtifactJunctionCapability:
          packageLocalArtifactJunctionCapability,
      consumedProducts: consumedProducts,
      reconcileDependencies: reconcileDependencies,
    );
    final result = await assemble(
      workspace: workspace,
      productName: productName,
      deploymentTarget: deploymentTarget,
      packageIdentities: packageIdentities,
    );
    return result;
  }

  /// Collects the products of an earlier build of [productName] without
  /// rebuilding, for callers that cache builds by fingerprint.
  Future<SwiftPmBuildResult> assemble({
    required SwiftPmWorkspace workspace,
    required String productName,
    required IosDeploymentTarget deploymentTarget,
    Map<String, String> packageIdentities = const {},
  }) => engine.assembly.discoverAndRewriteDylibs(
    targetDebugDirectory(workspace, deploymentTarget),
    productName: productName,
    packageIdentities: packageIdentities,
  );
}
