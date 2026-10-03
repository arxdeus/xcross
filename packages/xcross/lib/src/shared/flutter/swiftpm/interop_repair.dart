import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmInteropRepair<T extends PlatformHostInterface> {
  SwiftPmInteropRepair(this.runtime);
  final SwiftPmRuntime<T> runtime;

  /// A compiler diagnostic naming a generated `<Target>-Swift.h` header that
  /// could not be found.
  static final RegExp _missingSwiftHeaderDiagnostic = RegExp(
    r'[A-Za-z_0-9-]+-Swift\.h[^\n]*(?:file not found|not found|No such file)',
    caseSensitive: false,
  );

  Future<bool> normalizeResolvedPackageManifests(String scratchPath) async {
    final checkouts = Directory(p.join(scratchPath, 'checkouts'));
    var changed = false;
    if (checkouts.existsSync()) {
      for (final checkout in checkouts.listSync(followLinks: false)) {
        if (checkout is Directory) {
          changed =
              await runtime.checkout.normalizeVendoredPackageManifests(
                checkout.path,
                consumedProducts: const {},
              ) ||
              changed;
        }
      }
    }
    return changed;
  }

  /// Repairs and retries a [build] whose generated Swift interop header is
  /// missing.
  ///
  /// SwiftPM can schedule an Objective-C consumer after writing a Swift
  /// target's module map but before compiling the target that emits the
  /// referenced `-Swift.h`. Prebuilding each affected target establishes the
  /// missing output before the aggregate build resumes. Windows retains its
  /// existing one-retry fallback for compatibility modules whose failure does
  /// not leave a missing generated-header reference behind.
  Future<void> buildWithInteropRecovery({
    required Future<void> Function() build,
    required Future<void> Function(String target) buildTarget,
    required String targetBuildDir,
    required Set<String> interopTargetCandidates,
    Future<void> Function()? repairConsumers,
    bool skipInitialRecovery = false,
  }) async {
    final repair = repairConsumers ?? () async {};

    Future<bool> recoverMissingTargets({Set<String>? candidates}) async {
      final targets = SwiftPmInteropRepair.missingSwiftInteropTargets(
        targetBuildDir,
        candidates: candidates ?? interopTargetCandidates,
      );
      for (final target in targets) {
        await buildTarget(target);
      }
      if (targets.isNotEmpty) await repair();
      return targets.isNotEmpty;
    }

    // Prebuild every target the plan says will emit a `-Swift.h`, before any
    // consumer of it is scheduled. Recovering after the fact cannot be made
    // reliable here: SwiftPM compiles an Objective-C consumer concurrently
    // with the Swift target whose header it imports, so whether the build
    // succeeds depends on which finishes first. That is why the same
    // checkout failed on `header not found`, then on `module not found`, then
    // elsewhere, moving a little further each run as another header happened
    // to land.
    final planned = runtime.buildPlan.plannedSwiftInteropTargets(
      targetBuildDir,
      candidates: interopTargetCandidates,
    );
    final prebuild = runtime.hostPolicy.orderInteropTargets(
      targetBuildDir,
      planned,
    );
    for (final target in prebuild) {
      await buildTarget(target);
    }
    await repair();
    if (!skipInitialRecovery && await recoverMissingTargets()) {
      await build();
      return;
    }

    final before = SwiftPmBuildPlan.swiftInteropSearchPaths(
      targetBuildDir,
    ).toSet();
    final missingBefore = SwiftPmInteropRepair.missingSwiftInteropTargets(
      targetBuildDir,
      candidates: interopTargetCandidates,
    ).toSet();
    try {
      await build();
    } on Object catch (error, stack) {
      final missingHeader = _missingSwiftHeaderDiagnostic.hasMatch(
        error.toString(),
      );
      final newlyExposed = SwiftPmInteropRepair.missingSwiftInteropTargets(
        targetBuildDir,
        candidates: interopTargetCandidates,
      ).toSet().difference(missingBefore);
      if (!missingHeader && newlyExposed.isEmpty) rethrow;

      // Step 1: prebuild the targets whose header is still missing, then
      // retry. A failure here reports the original build error.
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

      // Step 2 (Windows only): the build emitted new interop search paths,
      // so repair their consumers once and retry.
      final emitted = SwiftPmBuildPlan.swiftInteropSearchPaths(
        targetBuildDir,
      ).toSet().difference(before);
      await runtime.hostPolicy.recoverEmittedInterop(
        emitted,
        repair,
        build,
        error,
        stack,
      );
    }
  }

  /// [interopTargetCandidates] plus every target the aggregate build plan
  /// reaches. Internal targets may be absent from public products, but must
  /// still be reachable from the generated aggregate build plan.
  Set<String> reachableInteropCandidates(
    String targetBuildDir,
    Set<String> interopTargetCandidates,
  ) {
    final reachable = SwiftPmBuildPlan.plannedTargetClosure(
      targetBuildDir,
      pluginsProductName,
    );
    return {...interopTargetCandidates, if (reachable != null) ...reachable};
  }

  /// Runs a recovery [step] for a build that failed with [error], rethrowing
  /// that original failure with its [stack] if the step itself fails, since
  /// the original diagnostic is the one a user can act on.
  Future<T> reportingOriginalFailure<T>(
    Object error,
    StackTrace stack,
    Future<T> Function() step,
  ) async {
    try {
      return await step();
    } on Object {
      Error.throwWithStackTrace(error, stack);
    }
  }

  static List<String> missingSwiftInteropTargets(
    String targetBuildDir, {
    required Set<String> candidates,
  }) {
    final directory = Directory(targetBuildDir);
    if (!directory.existsSync()) return const [];
    // A target the aggregate never reaches is never scheduled, so it cannot
    // be the one whose header a consumer raced. Its module map still names
    // an `-Swift.h` that no build will ever write, so without this filter
    // recovery rebuilds the same targets on every single run and never
    // converges. See [plannedSwiftInteropTargets] for the same reasoning.
    final reachable = SwiftPmBuildPlan.plannedTargetClosure(
      targetBuildDir,
      pluginsProductName,
    );
    final targets = <String>{};
    final headerPattern = RegExp(r'\bheader\s+"([^"]+-Swift\.h)"');
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! Directory || !p.basename(entity.path).endsWith('.build')) {
        continue;
      }
      final include = p.join(entity.path, 'include');
      final moduleMap = File(p.join(include, 'module.modulemap'));
      if (!moduleMap.existsSync()) continue;
      for (final match in headerPattern.allMatches(
        moduleMap.readAsStringSync(),
      )) {
        final reference = match.group(1)!;
        final header = p.isAbsolute(reference)
            ? reference
            : p.join(include, reference);
        if (File(header).existsSync()) continue;
        final basename = p.basename(reference);
        final target = basename.substring(
          0,
          basename.length - '-Swift.h'.length,
        );
        if (reachable != null && !reachable.contains(target)) continue;
        if (candidates.contains(target)) {
          targets.add(target);
        }
      }
    }
    final sorted = targets.toList()..sort();
    return sorted;
  }

  static Set<String> dependencyProductNames(String manifest) => {
    for (final call in SwiftPmManifest.swiftCalls(manifest, '.product'))
      if (SwiftPmManifest.namedString(call.text, 'name') case final String name)
        name,
  };

  Future<void> repairSwiftInteropConsumers({
    required String targetBuildDir,
    required Map<String, Set<String>> consumerProducts,
  }) async {
    final importsByProduct = <String, List<String>>{};
    final importPattern = RegExp(
      r'^\s*@import\s+([A-Za-z_][A-Za-z0-9_]*)\s*;',
      multiLine: true,
    );
    for (final product in {
      for (final products in consumerProducts.values) ...products,
    }) {
      final header = File(
        p.join(targetBuildDir, '$product.build', 'include', '$product-Swift.h'),
      );
      if (!header.existsSync()) continue;
      final imports = {
        for (final match in importPattern.allMatches(header.readAsStringSync()))
          if (match.group(1)! != product) match.group(1)!,
      }.toList()..sort();
      if (imports.isNotEmpty) importsByProduct[product] = imports;
    }

    for (final MapEntry(key: consumer, value: products)
        in consumerProducts.entries) {
      final directory = Directory(consumer);
      if (!directory.existsSync()) continue;
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File ||
            !const {'.h', '.m', '.mm'}.contains(p.extension(entity.path))) {
          continue;
        }
        var source = await entity.readAsString();
        final newline = source.contains('\r\n') ? '\r\n' : '\n';
        final original = source;
        for (final product in products) {
          final imports = importsByProduct[product];
          if (imports == null) continue;
          final marker = '@import $product;';
          final markerStart = source.indexOf(marker);
          if (markerStart == -1) continue;
          final missing = [
            for (final imported in imports)
              if (!source.contains('@import $imported;')) '@import $imported;',
          ];
          if (missing.isEmpty) continue;
          var insertAt = markerStart + marker.length;
          if (source.startsWith('\r\n', insertAt)) {
            insertAt += 2;
          } else if (source.startsWith('\n', insertAt) ||
              source.startsWith('\r', insertAt)) {
            insertAt++;
          } else {
            source = source.replaceRange(insertAt, insertAt, newline);
            insertAt += newline.length;
          }
          source = source.replaceRange(
            insertAt,
            insertAt,
            '${missing.join(newline)}$newline',
          );
        }
        if (source != original) {
          await runtime.filesystem.writeStable(entity.path, source);
        }
      }
    }
  }
}
