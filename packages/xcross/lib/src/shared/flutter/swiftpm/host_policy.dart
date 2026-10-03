import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

abstract interface class SwiftPmHostPolicy {
  Future<void> stageFlutterFramework<T extends PlatformHostInterface>(SwiftPmRuntime<T> runtime, String source, String destination, {bool? copy});
  String artifactIdentity(String value);
  List<String> get packagePrefix;
  List<String> get buildPrefix;
  String get packageTool;
  String get buildTool;
  List<String> get manifestArguments;
  List<String> get buildArguments;
  List<String> get linkerArguments;
  List<String> get fingerprintArguments;
  List<String> get gitConfiguration;
  Map<String, String> get sourceEnvironment;
  bool get sourceFallbackActive;
  Future<void> resolveDependencies(Future<void> Function() resolve);
  Future<bool> repairBuildPlan(String scratchPath, String targetBuildDir);
  Future<void> invokeBuild(
    Future<void> Function() build,
    String scratchPath,
    String targetBuildDir,
  );
  Future<void> rewriteDylib(String path, Set<String> names);
  List<String> orderInteropTargets(String root, List<String> targets);
  bool includesInteropTarget(String target, Set<String> candidates);
  Future<void> recoverEmittedInterop(
    Set<String> emitted,
    Future<void> Function() repair,
    Future<void> Function() build,
    Object error,
    StackTrace stack,
  );
  Future<String?> cCompiler(String sysroot, DarwinToolchainResolver toolchain);
  Future<String?> cxxCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  );
  Future<void> configureToolset(
    Map<String, Object> toolset,
    String linker,
    String? cc,
    String? cxx,
    Future<String?> Function(String) resolve,
  );
  bool get captureBuildOutput;

  Map<String, String> bundledToolEnvironment(
    PlatformHostInterface host,
    String executable,
    Map<String, String> environment,
  );
  List<String> linkerPathArguments(String path);
  String checkoutLinkText(String text);
  List<String> get checkoutArguments;
  void createRelativeLink(String link, String target);
  Future<void> clearPlaceholderAttributes<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String path,
  );
  Future<List<String>> cloneConfiguration(HostSymlinkCapability symlinks);
  Future<bool> materializeFallback<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String root,
    Map<String, String> links,
    Map<String, String> targets,
    Map<String, String> resolved,
    List<Map<String, Object?>> records,
  );
  Future<void> materializeClone<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String destination,
    String git,
    String vendorDir,
  );
  Future<({Map<String, String> pins, Map<String, String> originals})>
  bootstrapPinnedDependencies<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    Iterable<String> packages,
    String vendorDir,
    Future<void> Function(String, String, String, String)? clone,
  );
  Future<void> prepareBinaryArtifacts<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String packageRoot,
    String store,
    String fallback,
    bool capability,
  );
  Future<bool> recoverDependencyArtifacts<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String packageRoot,
    String scratchPath,
    String store,
    String fallback,
    List<SwiftPmPackageDependency> dependencies,
    SwiftPmBinaryAttemptState state,
    bool capability,
  );
  Future<Map<String, Object>> buildToolchainIdentity<
    T extends PlatformHostInterface
  >(SwiftPmRuntime<T> runtime, DarwinSdk? sdk);
  SwiftPmGatePlatform get gatePlatform;
}
