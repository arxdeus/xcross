import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_consumer_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plan_reader.dart';

@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmInteropBuildRecovery<T extends PlatformHostInterface> {
  SwiftPmInteropBuildRecovery({
    required this.session,
    required this.planReader,
    required this.consumerRepair,
    required this.hostPolicy,
    required this.execution,
  });
  final SwiftPmInteropBuild session;
  final SwiftPmPlanReader planReader;
  final SwiftPmInteropConsumerRepair<T> consumerRepair;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmBuildExecution<T> execution;
  static final RegExp _missingSwiftHeaderDiagnostic = RegExp(
    r'[A-Za-z_0-9-]+-Swift\.h[^\n]*(?:file not found|not found|No such file)',
    caseSensitive: false,
  );
  Future<void> build({
    required String targetBuildDir,
    required Set<String> interopTargetCandidates,
    bool skipInitialRecovery = false,
  }) async {
    final repair = session.repairConsumers;
    final build = session.build;
    final dependencies = planReader.targetDependencies(targetBuildDir);
    Future<void> buildLayered(List<String> targets) async {
      for (final layer in SwiftPmPlanReader.layerTargetsByDependencies(
        dependencies,
        targets,
      )) {
        await session.buildTargets(layer);
      }
    }

    Future<bool> recoverMissingTargets({Set<String>? candidates}) async {
      final targets = consumerRepair.missingSwiftInteropTargets(
        targetBuildDir,
        candidates: candidates ?? interopTargetCandidates,
      );
      await buildLayered(targets);
      if (targets.isNotEmpty) await repair();
      return targets.isNotEmpty;
    }

    final planned = planReader.plannedSwiftInteropTargets(targetBuildDir);
    await buildLayered(
      hostPolicy.selectInteropTargets(
        planned,
        interopTargetCandidates,
        planReader.interopTargetsReachedByNonSwiftTargets(targetBuildDir),
      ),
    );
    await repair();
    if (!skipInitialRecovery && await recoverMissingTargets()) {
      await build();
      return;
    }

    final before = planReader.swiftInteropSearchPaths(targetBuildDir).toSet();
    final missingBefore = consumerRepair
        .missingSwiftInteropTargets(
          targetBuildDir,
          candidates: interopTargetCandidates,
        )
        .toSet();
    try {
      await build();
    } on Object catch (error, stack) {
      final missingHeader = _missingSwiftHeaderDiagnostic.hasMatch(
        error.toString(),
      );
      final newlyExposed = consumerRepair
          .missingSwiftInteropTargets(
            targetBuildDir,
            candidates: interopTargetCandidates,
          )
          .toSet()
          .difference(missingBefore);
      if (!missingHeader && newlyExposed.isEmpty) rethrow;

      final candidates = reachableInteropCandidates(
        targetBuildDir,
        interopTargetCandidates,
      );
      final recovered = await reportingOriginalFailure(error, stack, () async {
        if (!await recoverMissingTargets(candidates: candidates)) {
          return false;
        }
        await build();
        return true;
      });
      if (recovered) return;

      final emitted = planReader
          .swiftInteropSearchPaths(targetBuildDir)
          .toSet()
          .difference(before);
      await execution.recoverInterop(
        emitted: emitted,
        command: session.command,
        error: error,
        stack: stack,
      );
    }
  }

  Set<String> reachableInteropCandidates(
    String targetBuildDir,
    Set<String> interopTargetCandidates,
  ) {
    final reachable = planReader.plannedTargetClosure(
      targetBuildDir,
      pluginsProductName,
    );
    return {...interopTargetCandidates, if (reachable != null) ...reachable};
  }

  Future<R> reportingOriginalFailure<R>(
    Object error,
    StackTrace stack,
    Future<R> Function() step,
  ) async {
    try {
      return await step();
    } on Object {
      Error.throwWithStackTrace(error, stack);
    }
  }
}
