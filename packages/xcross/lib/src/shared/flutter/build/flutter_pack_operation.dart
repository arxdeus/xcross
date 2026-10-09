import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/flutter_packer.dart';
import 'package:xcross/src/shared/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/models/pack_result.dart';

@internal
abstract final class FlutterPackOperation {
  static Future<PackResult> pack<T extends PlatformHostInterface>({
    required FlutterBuildRuntime<T> runtime,
    required FlutterBuildOptions options,
    required String projectRoot,
  }) async {
    options.validate(
      supportsPrecompiledModes: runtime.policy.supportsPrecompiledModes,
    );
    final bundleId = runtime.bundleIds.resolve(projectRoot);
    final workspace = SwiftPmWorkspace.forProject(
      projectRoot,
      policy: runtime.policy,
      environment: runtime.runner.effectiveEnvironment,
    );
    final packer = FlutterPacker(
      runtime: runtime,
      projectRoot: projectRoot,
      bundleId: bundleId,
      options: options,
      artifactJunctionCapabilityResolver: () => runtime.plugins
          .resolveArtifactJunctionCapabilities(workspace: workspace),
    );
    final bundleDir = runtime.host.fileSystem.directory(
      p.join(packer.outputDirectory, '${packer.appName}.app'),
    );
    if (bundleDir.existsSync()) await bundleDir.delete(recursive: true);
    final built = await packer.pack();
    return PackResult(
      outputPath: built.appPath,
      bundleId: bundleId,
      projectRoot: projectRoot,
      dartDefines: built.dartDefines,
    );
  }
}
