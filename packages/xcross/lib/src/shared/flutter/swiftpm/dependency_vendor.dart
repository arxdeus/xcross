import 'dart:async';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_evaluator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_dependencies.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmDependencyVendor<T extends PlatformHostInterface> {
  SwiftPmDependencyVendor({required this.checkout,required this.checkoutManifestNormalizer,required this.dependencyPreparation,required this.runner,required this.dependencyEvaluator,required this.binaryProvenance,required this.processPolicy});
final SwiftPmBinaryProvenance<T> binaryProvenance;
final SwiftPmProcessPolicy<T> processPolicy;
final SwiftPmDependencyEvaluator<T> dependencyEvaluator;
  
  final SwiftPmCheckout<T> checkout;
  final SwiftPmCheckoutManifestNormalizer<T> checkoutManifestNormalizer;
  final SwiftPmDependencyPreparation<T> dependencyPreparation;
  final ProcessRunner<T> runner;

  /// Clones each `.package(url:)` dependency under [vendorDir], normalizes its
  /// host manifests, and rewrites the plugin manifest to `.package(path:)`.
  Future<String> vendorUrlPackagesAsPathDeps(
    String manifest, {
    required String vendorDir,
    required String packageDirectory,
    Map<String, List<String>>? fallbackSwiftModules,
    Future<String> Function(String name)? locateTool,
    Future<Map<String, String>> Function(String packageDirectory)?
    evaluateDependencyRefs,
    SwiftPmDependencyRefEvaluator? scopedDependencyRefEvaluator,
    Future<void> Function(
      String git,
      String url,
      String ref,
      String destination,
    )?
    clonePackage,
    Map<String, Map<String, List<String>>>? normalizationCache,
    Map<String, Future<Map<String, String>>>? evaluationCache,
    Map<String, Future<void>>? checkoutCache,
    String? scratchPath,

    String? binaryArtifactStore,

    String? binaryArtifactFallback,
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
  }) async {
    final deps = SwiftPmManifestDependencies.parseUrlPackageDeps(manifest);
    if (deps.isEmpty) return manifest;

    final locate = locateTool ?? runner.locateTool;
    final evaluate =
        scopedDependencyRefEvaluator ??
        (
          directory, {
          required scratchPath,
          required binaryArtifactStore,
          required binaryArtifactFallback,
          required swiftPmArtifactJunctionCapability,
          required packageLocalArtifactJunctionCapability,
          required dependencies,
        }) => evaluateDependencyRefs != null
            ? evaluateDependencyRefs(directory)
            : dependencyEvaluator.evaluatedDependencyRefs(
                directory,
                locate,

                scratchPath: scratchPath,
                binaryArtifactStore: binaryArtifactStore,
                binaryArtifactFallback: binaryArtifactFallback,
                swiftPmArtifactJunctionCapability:
                    swiftPmArtifactJunctionCapability,
                dependencies: dependencies,
              );
    Future<Map<String, String>> evaluateCached(
      String manifest,
      String directory,
      List<SwiftPmPackageDependency> dependencies,
    ) async {
      Future<Map<String, String>> run() => evaluate(
        directory,
        scratchPath: scratchPath,
        binaryArtifactStore: binaryArtifactStore,
        binaryArtifactFallback: binaryArtifactFallback,
        swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
        packageLocalArtifactJunctionCapability:
            packageLocalArtifactJunctionCapability,
        dependencies: dependencies,
      );
      if (evaluationCache == null) return run();
      final evaluationKey = await binaryProvenance.dependencyEvaluationKey(manifest, directory);
      final pending = evaluationCache.putIfAbsent(evaluationKey, run);
      try {
        return await pending;
      } on Object {
        if (identical(evaluationCache[evaluationKey], pending)) {
          final _ = evaluationCache.remove(evaluationKey);
        }
        rethrow;
      }
    }

    final evaluatedRefs = await evaluateCached(
      manifest,
      packageDirectory,
      deps,
    );
    late final String git;
    try {
      git = await locate('git');
    } on CliError {
      throw FlutterBuildError(
        'Git is required to vendor SwiftPM URL dependencies '
        '(e.g. Firebase or sentry-cocoa). Install Git and ensure it is on PATH.',
      );
    }

    final clone = clonePackage ?? checkout.repository.cloneGitPackage;

    Future<void> cloneAndMaterialize(
      String url,
      String ref,
      String destination,
    ) async {
      await clone(git, url, ref, destination);
      if (clonePackage == null) {
        await dependencyPreparation.materializeClone(destination,git,vendorDir);
      }
    }

    Future<void> checkoutDependency(String url, String ref, String destination) async {
      if (checkoutCache == null) {
        await cloneAndMaterialize(url, ref, destination);
        return;
      }
      final key = p.normalize(destination);
      final pending = checkoutCache.putIfAbsent(
        key,
        () => cloneAndMaterialize(url, ref, destination),
      );
      try {
        await pending;
      } on Object {
        if (identical(checkoutCache[key], pending)) {
          final _ = checkoutCache.remove(key);
        }
        rethrow;
      }
    }

    return vendorUrlDeps(
      manifest,
      vendorDir: vendorDir,
      evaluatedRefs: evaluatedRefs,
      checkout: checkoutDependency,
      vendored: <String>{},
      requireResolvedRefs: true,
      evaluateNested: evaluateCached,
      fallbackSwiftModules: processPolicy.sourceFallbackActive ? fallbackSwiftModules : null,
      normalizationCache: normalizationCache,
    );
  }

  /// Rewrites every `.package(url:)` in [manifest] to a `.package(path:)`
  /// under [vendorDir], checking the revision out when it is not vendored
  /// yet and applying the same rewrite to that checkout's own manifests.
  ///
  /// Recursion is what keeps one identity per package: a dependency reachable
  /// both directly and transitively (SDWebImage via `flutter_image_compress`
  /// and via SDWebImageWebPCoder) resolves to the same `vendor/<name>@<ref>`
  /// directory instead of a path identity plus a git identity, which SwiftPM
  /// rejects as conflicting product names.
  Future<String> vendorUrlDeps(
    String manifest, {
    required String vendorDir,
    required Map<String, String> evaluatedRefs,
    required Future<void> Function(String url, String ref, String destination)
    checkout,
    required Set<String> vendored,
    required bool requireResolvedRefs,
    Future<Map<String, String>> Function(
      String manifest,
      String packageDirectory,
      List<SwiftPmPackageDependency> dependencies,
    )?
    evaluateNested,
    Map<String, List<String>>? fallbackSwiftModules,
    Map<String, Map<String, List<String>>>? normalizationCache,
  }) async {
    final deps = SwiftPmManifestDependencies.parseUrlPackageDeps(manifest);
    if (deps.isEmpty) return manifest;

    var result = manifest;
    final namedPathDeps = SwiftPmManifestDependencies.supportsNamedPathDeps(manifest);
    for (final dep in deps) {
      final ref = evaluatedRefs[SwiftPmBinaryProvenance.canonicalGitUrl(dep.url)];
      if (ref == null) {
        // The root resolution pins the whole transitive graph, so a missing
        // pin only happens for manifest variants SwiftPM itself ignores.
        // Leaving those as URL deps preserves the pre-recursion behaviour.
        if (!requireResolvedRefs) continue;
        throw FlutterBuildError(
          'Cannot vendor SwiftPM dependency ${dep.url}: Package.resolved '
          'contains no matching source-control revision.',
        );
      }
      final dirName = SwiftPmManifestDependencies.vendorPackageDirName(dep.url, ref);
      // Always set name: — without it SwiftPM uses the directory basename
      // (`pkg@1.2.3`), which breaks `.product(..., package: "pkg")`.
      final identity = dep.identity;
      final destination = p.join(vendorDir, dirName);
      if (vendored.add(p.normalize(destination))) {
        await checkout(dep.url, ref, destination);
        final consumedProducts = SwiftPmManifestDependencies.consumedProducts(
          manifest,
          identity,
        );

        final cacheKey = [
          p.normalize(destination),
          ...(consumedProducts.toList()..sort()),
        ].join('\u0000');
        final cachedModules = normalizationCache?[cacheKey];
        if (cachedModules == null) {
          final existingModules =
              fallbackSwiftModules?.keys.toSet() ?? const {};
          await checkoutManifestNormalizer.normalizeVendoredPackageManifests(
            destination,
            consumedProducts: consumedProducts,
            fallbackSwiftModules: processPolicy.sourceFallbackActive ? fallbackSwiftModules : null,
            rewriteDependencies: (nested) async {
              // A vendored package's manifest may declare deps the parent's
              // resolution never saw (firebase-ios-sdk hides them behind
              // `#if os(macOS)` until normalizeHostManifest exposes them).
              // Leaving those as URL deps forks the identity: this package
              // gets `<name>@<ref>` while the URL dep pulls `<name>` — so
              // resolve the checkout itself and vendor them too.
              var refs = evaluatedRefs;
              final nestedDeps = SwiftPmManifestDependencies.parseUrlPackageDeps(nested);
              if (evaluateNested != null &&
                  nestedDeps.any(
                    (dep) => !refs.containsKey(
                      SwiftPmBinaryProvenance.canonicalGitUrl(dep.url),
                    ),
                  )) {
                refs = {
                  ...await evaluateNested(nested, destination, nestedDeps),
                  ...evaluatedRefs,
                };
              }
              return vendorUrlDeps(
                nested,
                vendorDir: vendorDir,
                evaluatedRefs: refs,
                checkout: checkout,
                vendored: vendored,
                requireResolvedRefs: false,
                evaluateNested: evaluateNested,
                fallbackSwiftModules: processPolicy.sourceFallbackActive ? fallbackSwiftModules : null,
                normalizationCache: normalizationCache,
              );
            },
          );
          normalizationCache?[cacheKey] = fallbackSwiftModules == null
              ? {}
              : {
                  for (final entry in fallbackSwiftModules.entries)
                    if (!existingModules.contains(entry.key))
                      entry.key: List<String>.of(entry.value),
                };
        } else {
          fallbackSwiftModules?.addAll({
            for (final entry in cachedModules.entries)
              entry.key: List<String>.of(entry.value),
          });
        }
      }
      final pathDep = namedPathDeps
          ? '.package(name: "$identity", '
                'path: "${SwiftPmFilesystem.swiftPath(destination)}")'
          : '.package(path: "${SwiftPmFilesystem.swiftPath(destination)}")';
      result = result.replaceFirst(dep.match, pathDep);
    }
    return result;
  }
}
