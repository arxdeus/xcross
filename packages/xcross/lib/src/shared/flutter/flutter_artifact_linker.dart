import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/app_extension_builder.dart';
import 'package:xcross/src/flutter/build/internal/runner_binary.dart';
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/flutter/extensions/app_extension_resources.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';

final class FlutterArtifactLinker<T extends PlatformHostInterface>
    implements FlutterLinkStep<T> {
  FlutterArtifactLinker(this.context);
  final FlutterBuildContext<T> context;
  FlutterBuildRuntime<T> get runtime => context.runtime;
  String get projectRoot => context.projectRoot;
  String get bundleId => context.bundleId;
  FlutterBuildOptions get options => context.options;
  IosBundleVersions get _versions => context.versions;
  String _buildDirectory(String name) =>
      runtime.policy.buildDirectory(projectRoot, name);
  @override
  Future<FlutterLinkedArtifacts> link(FlutterCompiledArtifacts compiled) async {
    final flutterRoot = context.flutterRoot;
    final deploymentTarget = context.deploymentTarget;
    final requiredNativeFrameworks = await runtime.nativeAssetFrameworks
        .requiredByPlugins(
          compiled.nativeAssets.frameworks,
          compiled.plugins?.dylibPaths ?? const [],
        );
    final runnerResult = await _buildRunnerBinary(
      flutterRoot,
      deploymentTarget: deploymentTarget,
      pluginsLibrary: compiled.plugins?.libraryPath,
      nativeAssetFrameworks: requiredNativeFrameworks,
      verbose: runtime.runner.log.isVerbose,
    );

    final extensions = await _buildAppExtensions(
      deploymentTarget: deploymentTarget,
      flutterXcframework: runnerResult.xcframework,
      pluginsBuild: compiled.plugins,
    );

    return FlutterLinkedArtifacts(
      compiled: compiled,
      runner: runnerResult,
      extensions: extensions,
    );
  }

  Future<List<BuiltAppExtension>> _buildAppExtensions({
    required IosDeploymentTarget deploymentTarget,
    required String flutterXcframework,
    GeneratedPluginsBuildResult? pluginsBuild,
  }) async {
    final discovered = runtime.extensions.discover(projectRoot);
    if (discovered.isEmpty) return const [];

    final buildable = <IosAppExtension>[];
    for (final extension in discovered) {
      if (extension.suffixUnder(bundleId) == null) {
        runtime.runner.log.logWarn(
          'Skipping app extension "${extension.name}": its bundle id '
          '${extension.bundleId} is not nested under the app id $bundleId.',
        );
        continue;
      }
      buildable.add(extension);
    }

    return AppExtensionBuilder(
      runtime,
      AppExtensionResources(
        fileSystem: runtime.host.fileSystem,
        log: runtime.runner.log,
      ),
    ).buildAll(
      projectRoot: projectRoot,
      extensions: buildable,
      deploymentTarget: deploymentTarget,
      outputDir: _buildDirectory('xcross-flutter-extensions'),
      versions: _versions,
      flutterXcframework: flutterXcframework,
      pluginsLibrary: pluginsBuild?.libraryPath,
      pluginModulesDir: pluginsBuild?.modulesDir,
    );
  }

  /// Compile the ObjC Runner shim and return both the xcframework path and the
  /// linked Runner binary path.
  Future<RunnerBinary> _buildRunnerBinary(
    String flutterRoot, {
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
    String? pluginsLibrary,
    List<String> nativeAssetFrameworks = const [],
  }) async {
    final xcframework = runtime.engineCache(flutterRoot).flutterXcframework;

    final darwin = runtime.sdkRepository.current();
    if (darwin == null) {
      throw FlutterBuildError(
        'FlutterPacker: Darwin SDK not found. '
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }

    final runnerBinary = await RunnerShim(runtime).buildRunnerBinary(
      projectRoot: projectRoot,
      sdk: darwin,
      flutterXcframework: xcframework,
      outputDir: _buildDirectory('xcross-flutter-runner-bin'),
      deploymentTarget: deploymentTarget,
      pluginsLibrary: pluginsLibrary,
      nativeAssetFrameworks: nativeAssetFrameworks,
      verbose: verbose,
    );

    return RunnerBinary(
      xcframework: xcframework,
      runnerBinary: runnerBinary,
      sdkName: p
          .basenameWithoutExtension(
            runtime.sdkRepository.iosSdk(
              darwin,
              target: deploymentTarget.platform,
            ),
          )
          .toLowerCase(),
    );
  }
}
