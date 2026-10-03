import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_capabilities.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
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
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/module_files.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plugin_overlay.dart';
import 'package:xcross/src/shared/flutter/swiftpm/preview_macro_compiler.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';
import 'package:xcross/src/shared/flutter/swiftpm/workspace_stager.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';


final class SwiftPmGateExecution<T extends PlatformHostInterface> {
SwiftPmGateExecution({required this.runner,required this.sdkRepository,required this.toolchain,required this.processPolicy,required this.buildPlan,required this.target,required this.artifactFileSystem});
final ProcessRunner<T> runner;
final DarwinSdkRepository<T> sdkRepository;
final SwiftPmToolchain<T> toolchain;
final SwiftPmProcessPolicy<T> processPolicy;
final SwiftPmBuildPlan<T> buildPlan;
final IosTarget<T> target;
final SwiftPmArtifactFileSystem artifactFileSystem;
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
