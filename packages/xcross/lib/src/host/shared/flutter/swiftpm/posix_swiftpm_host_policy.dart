import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_order.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

abstract class PosixSwiftPmHostPolicy implements SwiftPmHostPolicy {
  const PosixSwiftPmHostPolicy();
  @override
  String artifactIdentity(String value)=>value;
  @override
  Future<void> stageFlutterFramework<T extends PlatformHostInterface>(SwiftPmRuntime<T> runtime, String source, String destination, {bool? copy}) => runtime.filesystem.stageFlutterFramework(source, destination, copy: copy ?? false);
  @override
  List<String> get packagePrefix => const ['package'];
  @override
  List<String> get buildPrefix => const ['build'];
  @override
  String get packageTool => 'swift';
  @override
  String get buildTool => 'swift';
  @override
  List<String> get manifestArguments => const [];
  @override
  List<String> get buildArguments => const [];
  @override
  List<String> get linkerArguments => objectiveCSmallStubSwiftDriverArguments;
  @override
  List<String> get fingerprintArguments => const [];
  @override
  List<String> get gitConfiguration => const [];
  @override
  Map<String, String> get sourceEnvironment => const {};
  @override
  bool get sourceFallbackActive => false;
  @override
  bool get captureBuildOutput => false;
  @override
  Future<void> resolveDependencies(Future<void> Function() resolve) async {}
  @override
  Future<bool> repairBuildPlan(
    String scratchPath,
    String targetBuildDir,
  ) async => false;
  @override
  Future<void> invokeBuild(
    Future<void> Function() build,
    String scratchPath,
    String targetBuildDir,
  ) => build();
  @override
  List<String> orderInteropTargets(String root, List<String> targets) =>
      targets;
  @override
  bool includesInteropTarget(String target, Set<String> candidates) =>
      candidates.contains(target);
  @override
  Future<void> recoverEmittedInterop(
    Set<String> emitted,
    Future<void> Function() repair,
    Future<void> Function() build,
    Object error,
    StackTrace stack,
  ) async {
    Error.throwWithStackTrace(error, stack);
  }

  @override
  Future<String?> cCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  ) async => null;
  @override
  Future<String?> cxxCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  ) async => null;
  @override
  Future<void> configureToolset(
    Map<String, Object> toolset,
    String linker,
    String? cc,
    String? cxx,
    Future<String?> Function(String) resolve,
  ) async {}

  @override
  Map<String, String> bundledToolEnvironment(
    PlatformHostInterface host,
    String executable,
    Map<String, String> environment,
  ) => const {};
  @override
  List<String> linkerPathArguments(String path) => [
    '-Xswiftc',
    '-Xclang-linker',
    '-Xswiftc',
    '--ld-path=$path',
  ];
  @override
  String checkoutLinkText(String text) => text;
  @override
  List<String> get checkoutArguments => const [];
  @override
  void createRelativeLink(String link, String target) =>
      Link(link).createSync(target);
  @override
  Future<void> clearPlaceholderAttributes<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String path,
  ) async {}
  @override
  Future<List<String>> cloneConfiguration(
    HostSymlinkCapability symlinks,
  ) async => const [];
  @override
  Future<bool> materializeFallback<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String root,
    Map<String, String> links,
    Map<String, String> targets,
    Map<String, String> resolved,
    List<Map<String, Object?>> records,
  ) async {
    var changed = false;
    for (final link in orderCheckoutLinks(links, resolved)) {
      final target = resolved[link]!;
      if (Directory(target).existsSync()) {
        records.add({'path': link, 'kind': 'directory', 'target': target});
        await runtime.filesystem.deleteUnless(
          link,
          FileSystemEntityType.directory,
        );
        changed =
            await runtime.filesystem.syncDirectory(target, link) || changed;
      } else {
        records.add({
          'path': link,
          'kind': 'hardlink',
          'target': targets[link],
        });
        changed =
            await runtime.filesystem.syncFile(File(target), link) || changed;
      }
    }
    return changed;
  }

  @override
  Future<void> materializeClone<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String destination,
    String git,
    String vendorDir,
  ) async {}
  @override
  Future<({Map<String, String> pins, Map<String, String> originals})>
  bootstrapPinnedDependencies<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    Iterable<String> packages,
    String vendorDir,
    Future<void> Function(String, String, String, String)? clone,
  ) async => (pins: <String, String>{}, originals: <String, String>{});
  @override
  Future<void> prepareBinaryArtifacts<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String packageRoot,
    String store,
    String fallback,
    bool capability,
  ) async {}
  @override
  Future<bool> recoverDependencyArtifacts<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String packageRoot,
    String scratchPath,
    String store,
    String fallback,
    List<SwiftPmPackageDependency> dependencies,
    SwiftPmBinaryAttemptState state,
    bool capability,
  ) async => false;
  @override
  Future<Map<String, Object>>
  buildToolchainIdentity<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    DarwinSdk? sdk,
  ) => runtime.sdkIdentity.hostToolchainIdentity();
  @override
  PosixSwiftPmGatePlatform get gatePlatform => const PosixSwiftPmGatePlatform();
}
