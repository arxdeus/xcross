import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/discovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plugin_overlay.dart';
import 'package:xcross/src/shared/flutter/swiftpm/workspace_stager.dart';
import 'package:xcross/src/shared/swiftpm/runtime.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

/// Flutter-specific SwiftPM staging on top of the generic [SwiftPmRuntime]:
/// the generated plugins manifest and registrant, plugin package overlays,
/// and plugin discovery fingerprints.
@internal
final class FlutterSwiftPmStaging<T extends PlatformHostInterface> {
  FlutterSwiftPmStaging(this.engine, this.flutterPolicy) {
    if (!identical(engine.targetPolicy, flutterPolicy)) {
      throw ArgumentError(
        'Flutter SwiftPM staging must share the engine target policy',
      );
    }
    manifest = SwiftPmManifest<T>(targetPolicy: flutterPolicy);
    pluginOverlay = SwiftPmPluginOverlay<T>(
      manifestPolicy: engine.checkoutManifestNormalizer.policy,
      filesystem: engine.filesystem,
      sourceNormalizer: engine.sourceNormalizer,
      binaryPreparation: engine.binaryPreparation,
    );
    workspaceStager = SwiftPmWorkspaceStager<T>(
      hostBuildServices: engine.hostBuildServices,
      artifactFileSystem: engine.artifactFileSystem,
      checkout: engine.checkout,
      dependencyPreparation: engine.dependencyPreparation,
      filesystem: engine.filesystem,
      hostPolicy: engine.hostPolicy,
      manifest: manifest,
      pluginOverlay: pluginOverlay,
      runner: engine.runner,
      sourceNormalizer: engine.sourceNormalizer,
      checkoutManifestNormalizer: engine.checkoutManifestNormalizer,
    );
    discovery = SwiftPmDiscovery<T>(
      hostPolicy: engine.hostPolicy,
      sdkIdentity: engine.sdkIdentity,
      sdkRepository: engine.sdkRepository,
      toolchain: engine.toolchain,
    );
  }

  final SwiftPmRuntime<T> engine;
  final FlutterTargetBuildPolicy<T> flutterPolicy;
  late final SwiftPmManifest<T> manifest;
  late final SwiftPmPluginOverlay<T> pluginOverlay;
  late final SwiftPmWorkspaceStager<T> workspaceStager;
  late final SwiftPmDiscovery<T> discovery;
}
