import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_consumer_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_target_alias.dart';

@internal
final class SwiftPmBuildSession<T extends PlatformHostInterface>
    implements SwiftPmInteropBuild {
  SwiftPmBuildSession({
    required this.execution,
    required this.command,
    required this.consumerRepair,
    required this.targetAlias,
  });
  final SwiftPmBuildExecution<T> execution;
  @override
  final SwiftPmBuildCommand command;
  final SwiftPmInteropConsumerRepair<T> consumerRepair;
  final SwiftPmManifestTargetAlias targetAlias;
  bool _manifestCurrent = false;
  @override
  Future<void> build() async {
    await execution.execute(command);
    _manifestCurrent = true;
  }

  @override
  Future<void> buildTarget(String target) async {
    await execution.execute(
      SwiftPmBuildCommand(
        executable: command.executable,
        arguments: [...command.arguments, '--target', target],
        environment: command.environment,
        scratchPath: command.scratchPath,
        targetBuildDir: command.targetBuildDir,
        consumerProducts: command.consumerProducts,
      ),
    );
    _manifestCurrent = true;
  }

  @override
  Future<void> buildTargets(List<String> targets) async {
    var pending = targets;
    if (!_manifestCurrent && pending.isNotEmpty) {
      await buildTarget(pending.first);
      pending = pending.sublist(1);
    }
    if (pending.isEmpty) return;
    final [first, ...rest] = pending;
    if (rest.isEmpty) {
      await buildTarget(first);
      return;
    }
    final aliased = await targetAlias.withTargets(
      scratchPath: command.scratchPath,
      targetBuildDir: command.targetBuildDir,
      target: first,
      extra: rest,
      build: () => buildTarget(first),
    );
    if (aliased == true) return;
    for (final target in aliased == null ? pending : rest) {
      await buildTarget(target);
    }
  }

  @override
  Future<void> repairConsumers() => consumerRepair.repairSwiftInteropConsumers(
    targetBuildDir: command.targetBuildDir,
    consumerProducts: command.consumerProducts,
  );
}
