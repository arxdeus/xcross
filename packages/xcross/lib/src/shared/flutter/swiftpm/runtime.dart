import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_capabilities.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/assembly.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_driver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_links.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_vendor.dart';
import 'package:xcross/src/shared/flutter/swiftpm/discovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';
import 'package:xcross/src/shared/flutter/swiftpm/workspace_stager.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

final class SwiftPmRuntime<T extends PlatformHostInterface> {
  SwiftPmRuntime(
    this.targetPolicy,
    this.runner,
    this.sdkRepository,
    this.toolchainResolver,
    this.tools,
    this.hostPolicy,
    this.artifactFileSystem,
    this.sdkIdentity,
  );
  IosTarget<T> get target => targetPolicy.target;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  T get host => target.host;

  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> sdkRepository;
  final DarwinToolchainResolver<T> toolchainResolver;
  final AppleToolShimResolver<T> tools;
  late final symlinks = HostSymlinkCapability(host);
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmSdkIdentity sdkIdentity;
  bool? sourceFallbackOverride;
  late final artifactCapabilities = SwiftPmArtifactCapabilities<T>(this);
  late final workspaceStager = SwiftPmWorkspaceStager<T>(this);
  late final buildDriver = SwiftPmBuildDriver<T>(this);
  late final checkoutLinks = SwiftPmCheckoutLinks<T>(this);
  late final discovery = SwiftPmDiscovery<T>(this);
  late final assembly = SwiftPmAssembly<T>(this);
  late final checkout = SwiftPmCheckout<T>(this);
  late final interopRepair = SwiftPmInteropRepair<T>(this);
  late final manifest = SwiftPmManifest<T>(this);
  late final sourceRepair = SwiftPmSourceRepair<T>(this);
  late final sourceFallback = SwiftPmSourceFallback<T>(this);
  late final dependencyVendor = SwiftPmDependencyVendor<T>(this);
  late final filesystem = SwiftPmFilesystem<T>(this);
  late final toolchain = SwiftPmToolchain<T>(this);
  late final binaryRecovery = SwiftPmBinaryRecovery<T>(this);
  late final buildPlan = SwiftPmBuildPlan<T>(this);
  late final processPolicy = SwiftPmProcessPolicy<T>(this);
  Future<ProcessResult> runGateProcess(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  }) async {
    final process = await runner.start(
      executable,
      arguments,
      environment: environment,
    );
    try {
      final output = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final error = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(process.pid, exitCode, await output, await error);
    } on TimeoutException {
      await runner.killTree(process);
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
      rethrow;
    }
  }
}
