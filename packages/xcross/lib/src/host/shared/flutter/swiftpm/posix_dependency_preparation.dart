import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/network_retry.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';

@internal
final class PosixSwiftPmDependencyPreparation<T extends PlatformHostInterface>
    implements SwiftPmDependencyPreparation<T> {
  const PosixSwiftPmDependencyPreparation({
    required this.runner,
    required this.processPolicy,
    required this.networkRetry,
  });
  final ProcessRunner<T> runner;
  final SwiftPmProcessPolicy<T> processPolicy;
  final SwiftPmNetworkRetry<T> networkRetry;
  @override
  Future<void> prepare(SwiftPmDependencyCommand command) =>
      networkRetry.retryingTransientNetworkFailure(
        () => runner.runChecked(
          command.swift,
          processPolicy
              .swiftResolveArguments(
                pluginsDir: command.pluginsDir,
                scratchPath: command.scratchPath,
                swiftSdksPath: command.swiftSdksPath,
                toolsetPath: command.toolsetPath,
                swiftSdkTriple: command.swiftSdkTriple,
              )
              .toList(),
          environment: command.environment,
          inheritStdio: runner.log.isVerbose,
          label: 'swift package resolve',
        ),
        label: 'swift package resolve',
      );
}
