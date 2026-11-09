import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/build/flutter_aot_snapshotter.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/runtime/flutter_feature_services.dart';
import 'package:xcross/src/shared/swiftpm/apple_tool_shim_renderer.dart';
import 'package:xcross/src/shared/swiftpm/swiftpm_services.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

/// Flutter build services for one host. SwiftPM plugin builds go through the
/// host's shared [swiftPm] services.
@internal
final class HostFlutterFeatureServices<T extends PlatformHostInterface>
    implements FlutterFeatureServices<T> {
  const HostFlutterFeatureServices({
    required this.swiftPm,
    required this.repository,
    required this.toolchain,
    required this.hostTools,
    required this.renderer,
    required this.sdkPolicy,
    required this.resolution,
    required this.downloader,
    this.aotCompilers,
  });

  final SwiftPmServices<T> swiftPm;
  final IosAotCompilerLocator? aotCompilers;
  final Downloader downloader;
  @override
  ProcessRunner<T> get runner => swiftPm.runner;
  final DarwinSdkRepository<T> repository;
  final DarwinToolchainResolver<T> toolchain;
  final NativeHostTools<T> hostTools;
  final AppleToolShimRenderer<T> renderer;
  final FlutterSdkHostPolicy<T> sdkPolicy;
  final FlutterResolutionConfiguration resolution;

  @override
  FlutterBuildRuntime<T> build(FlutterTargetBuildPolicy<T> policy) {
    final plugins = GeneratedPluginsPackage<T>.withBuilder(
      policy,
      swiftPm.builder(policy),
    );
    return FlutterBuildRuntime(
      policy: policy,
      runner: runner,
      sdkRepository: repository,
      toolchain: toolchain,
      hostTools: hostTools,
      toolShimRenderer: renderer,
      sdkHostPolicy: sdkPolicy,
      downloader: downloader,
      plugins: plugins,
      resolution: resolution,
      aotCompilers: aotCompilers,
    );
  }
}
