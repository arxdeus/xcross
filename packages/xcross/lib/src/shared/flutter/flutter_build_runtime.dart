import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/xcconfig_resolver.dart';
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';
import 'package:xcross/src/flutter/build/ios_bundle_id.dart';
import 'package:xcross/src/flutter/build/ios_bundle_resources.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/artifact/plist_storyboard_policy.dart';
import 'package:xcross/src/shared/flutter/flutter_build_options_resolver.dart';
import 'package:xcross/src/shared/flutter/flutter_framework_copier.dart';
import 'package:xcross/src/shared/flutter/flutter_project_resolver.dart';
import 'package:xcross/src/shared/flutter/project/dart_defines_reader.dart';
import 'package:xcross/src/shared/flutter/project/ios_bundle_versions_resolver.dart';
import 'package:xcross/src/shared/flutter/project/ios_deployment_target_resolver.dart';
import 'package:xcross/src/shared/flutter/project/pbx_project_reader.dart';
import 'package:xcross/src/shared/flutter/project/pubspec_info_reader.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

final class FlutterResolutionConfiguration {
  const FlutterResolutionConfiguration({
    required this.executable,
    this.declarative = false,
    this.root,
    this.environmentRoot,
    this.tool,
    this.launcher,
    this.xcrun,
  });
  final bool declarative;
  final String? root;
  final String? environmentRoot;
  final String? tool;
  final String executable;
  final String? launcher;
  final String? xcrun;
}

final class FlutterBuildRuntime<T extends PlatformHostInterface> {
  FlutterBuildRuntime({
    required this.policy,
    required this.hostTools,
    required this.toolShimRenderer,
    required this.sdkHostPolicy,
    required this.runner,
    required this.sdkRepository,
    required this.toolchain,
    required this.plugins,
    required this.downloader,
    required this.resolution,
  }) {
    if (!identical(target.host, runner.host) ||
        !identical(target.host, sdkRepository.host) ||
        !identical(target.host, toolchain.host) ||
        !identical(target.host, hostTools.host) ||
        !identical(target.host, toolShimRenderer.host) ||
        !identical(policy, plugins.runtime.targetPolicy)) {
      throw ArgumentError(
        'Flutter runtime requires one coherent host instance',
      );
    }
  }
  late final DartDefinesReader defines = DartDefinesReader(
    host.fileSystem,
    host.paths.context,
  );
  late final FlutterBuildOptionsResolver options = FlutterBuildOptionsResolver(
    defines,
  );
  late final FlutterFrameworkCopier frameworks = FlutterFrameworkCopier(
    host.fileSystem,
    host.paths.context,
  );
  late final XcconfigResolver xcconfigs = XcconfigResolver(
    host.fileSystem,
    host.paths.context,
  );
  late final PlistStoryboardPolicy storyboards = PlistStoryboardPolicy(
    host.fileSystem,
    host.paths.context,
  );
  late final IosBundleResources resources = IosBundleResources(
    host.fileSystem,
    host.paths.context,
    projects,
  );
  late final PbxProjectReader projects = PbxProjectReader(
    host.fileSystem,
    host.paths.context,
  );
  late final IosBundleVersionsResolver versions = IosBundleVersionsResolver(
    host.fileSystem,
    projects,
  );
  late final IosBundleId bundleIds = IosBundleId(
    host.fileSystem,
    host.paths.context,
    projects,
  );
  late final IosAppExtensions extensions = IosAppExtensions(
    host.fileSystem,
    host.paths.context,
    projects,
  );

  late final PubspecInfoReader pubspecs = PubspecInfoReader(
    host.fileSystem,
    host.paths.context,
  );
  late final IosDeploymentTargetResolver deployments =
      IosDeploymentTargetResolver(host.fileSystem, host.paths.context);

  IosTarget<T> get target => policy.target;
  T get host => target.host;
  final ProcessRunner<T> runner;
  final GeneratedPluginsPackage<T> plugins;
  final Downloader downloader;
  final DarwinSdkRepository<T> sdkRepository;
  final DarwinToolchainResolver<T> toolchain;
  final FlutterResolutionConfiguration resolution;
  final FlutterTargetBuildPolicy<T> policy;
  final NativeHostTools<T> hostTools;
  final AppleToolShimRenderer<T> toolShimRenderer;
  final FlutterSdkHostPolicy<T> sdkHostPolicy;
  IosEngineCache<T> engineCache(String flutterRoot) => IosEngineCache(
    downloader: downloader,
    log: runner.log,
    hostTools: hostTools,
    targetPolicy: policy,
    flutterRoot: flutterRoot,
  );
  Future<String> resolveFlutterRoot({
    required String projectRoot,
    String? root,
  }) => FlutterProjectResolver(
    this,
  ).resolveFlutterRoot(projectRoot: projectRoot, root: root);
  AppleToolShimResolver<T> get nativeTools => AppleToolShimResolver(
    target,
    runner,
    sdkRepository,
    toolchain,
    hostTools: hostTools,
    executable: resolution.executable,
    launcher: resolution.launcher,
    xcrun: resolution.xcrun,
    declarative: resolution.declarative,
  );
}
