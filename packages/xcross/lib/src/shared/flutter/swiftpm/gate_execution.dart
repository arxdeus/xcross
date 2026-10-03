import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';


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
