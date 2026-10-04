import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_evaluator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_dependencies.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plugin_overlay.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmWorkspaceStager<T extends PlatformHostInterface> {
  SwiftPmWorkspaceStager({
    required this.artifactFileSystem,
    required this.checkout,
    required this.dependencyPreparation,
    required this.filesystem,
    required this.hostPolicy,
    required this.hostBuildServices,
    required this.manifest,
    required this.pluginOverlay,
    required this.runner,
    required this.sourceNormalizer,
    required this.dependencyEvaluator,
  });
  final SwiftPmDependencyEvaluator<T> dependencyEvaluator;
  final SwiftPmArtifactFileSystem artifactFileSystem;

  final SwiftPmCheckout<T> checkout;
  final SwiftPmDependencyPreparation<T> dependencyPreparation;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmHostBuildServices<T> hostBuildServices;
  final SwiftPmManifest<T> manifest;
  final SwiftPmPluginOverlay<T> pluginOverlay;
  final ProcessRunner<T> runner;
  final SwiftPmHostSourceNormalizer sourceNormalizer;

  /// Package-root entries a plugin's iOS SwiftPM build can never reach:
  /// Dart code, other platforms, development trees, and pub metadata.
  ///
  /// This is a sparse checkout by exclusion rather than inclusion because
  /// the reachable remainder has no fixed shape: published plugins refer
  /// to arbitrary sibling directories from their iOS package (`../../src`
  /// sources, `../../include` header search paths, shared `darwin/`
  /// trees), so only the provably unreachable entries are skipped.

  /// Identifiers a `.package(url:)` requirement may use as values without a
  /// declaration; argument labels (`from:`, `branch:`) are skipped separately.
  static const _dependencyCallIdentifiers = {'Version'};

  /// Writes the `FlutterFramework` and `Plugins` wrapper packages (manifests,
  /// registrant source, and the `Flutter.xcframework` link/copy) under
  /// [outputDir], without invoking `swift build`. Split out from [build] so
  /// the file-synthesis logic is testable without a Swift toolchain.
  ///
  /// When [vendorRemotePackages] is true (default on Windows), every
  /// `.package(url:)` dependency in a plugin manifest is cloned under
  /// `outputDir/Vendor/`, host-normalized, and rewritten to a `.package(path:)`
  /// so SwiftPM never host-evaluates broken remote manifests (e.g. sentry-cocoa
  /// `getenv` via removed `MSVCRT`).
  Future<void> writeGeneratedPackages({
    required String outputDir,
    required List<IosPlugin> plugins,
    required String flutterXcframework,
    required IosDeploymentTarget deploymentTarget,
    bool verbose = false,
    bool? copyFlutterXcframework,
    bool? vendorRemotePackages,
    String? vendorDir,
    Set<String> copyPluginPackages = const {},
    String? scratchPath,
    String? binaryArtifactStore,
    String? binaryArtifactFallback,
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
    SwiftPmDependencyRefEvaluator? evaluateDependencyRefs,
    Future<void> Function(
      String git,
      String url,
      String ref,
      String destination,
    )?
    clonePackage,
  }) async {
    final packagesDir = p.join(outputDir, 'Packages');
    final frameworkDir = p.join(packagesDir, flutterFrameworkPackageName);
    final pluginsDir = p.join(outputDir, 'Plugins');
    final resolvedVendorDir = vendorDir ?? p.join(outputDir, 'vendor');
    final shouldVendor = vendorRemotePackages ?? true;

    await artifactFileSystem.directory(packagesDir).create(recursive: true);
    await writeFlutterFrameworkPackage(
      frameworkDir: frameworkDir,
      flutterXcframework: flutterXcframework,
      copyFlutterXcframework: copyFlutterXcframework,
    );

    final pluginTargets = {
      for (final plugin in plugins) plugin.name: plugin.swiftPackageDir,
    };
    final pluginPackageDirs = <String, String>{};
    final vendorNormalizationCache = <String, Map<String, List<String>>>{};
    final dependencyEvaluationCache = <String, Future<Map<String, String>>>{};
    final vendorCheckoutCache = <String, Future<void>>{};

    var pluginRefEvaluator = evaluateDependencyRefs;
    if (shouldVendor) {
      // Stage every plugin with its URL deps intact first, then resolve them
      // as one graph: per-plugin resolution pins shared transitive packages
      // (gtm-session-fetcher via GoogleSignIn and via Firebase) at different
      // revisions, and two `vendor/<name>@<ref>` path packages with the same
      // products cannot coexist.
      final prestaged = <String>[];
      for (final plugin in plugins) {
        prestaged.add(
          await pluginOverlay.stagePluginPackage(
            alias: p.join(packagesDir, plugin.name),
            target: plugin.swiftPackageDir,
            platformDir: plugin.platformDirectoryName,
            packageTargets: pluginTargets,
            copySources: true,
            scratchPath: scratchPath,
            binaryArtifactStore: binaryArtifactStore,
            binaryArtifactFallback: binaryArtifactFallback,
            swiftPmArtifactJunctionCapability:
                swiftPmArtifactJunctionCapability,
            packageLocalArtifactJunctionCapability:
                packageLocalArtifactJunctionCapability,
          ),
        );
      }
      final scoped = evaluateDependencyRefs;
      final bootstrap = await dependencyPreparation.bootstrapPinned(
        SwiftPmPinnedDependencyCommand(
          packageDirectories: prestaged,
          vendorDir: resolvedVendorDir,
        ),
      );
      Map<String, String>? unified;
      try {
        unified = await resolveUnifiedDependencyRefs(
          resolveRoot: p.join(outputDir, 'Resolve'),
          packageDirectories: prestaged,
          evaluate: (directory, dependencies) => scoped != null
              ? scoped(
                  directory,
                  scratchPath: scratchPath,
                  binaryArtifactStore: binaryArtifactStore,
                  binaryArtifactFallback: binaryArtifactFallback,
                  swiftPmArtifactJunctionCapability:
                      swiftPmArtifactJunctionCapability,
                  packageLocalArtifactJunctionCapability:
                      packageLocalArtifactJunctionCapability,
                  dependencies: dependencies,
                )
              : dependencyEvaluator.evaluatedDependencyRefs(
                  directory,
                  runner.locateTool,

                  scratchPath: scratchPath,
                  binaryArtifactStore: binaryArtifactStore,
                  binaryArtifactFallback: binaryArtifactFallback,
                  swiftPmArtifactJunctionCapability:
                      swiftPmArtifactJunctionCapability,
                  dependencies: dependencies,
                ),
        );
      } finally {
        for (final entry in bootstrap.originals.entries) {
          await filesystem.writeStable(entry.key, entry.value);
        }
      }
      final pinned = {...?unified, ...bootstrap.pins};
      if (pinned.isNotEmpty) {
        pluginRefEvaluator =
            (
              _, {
              required scratchPath,
              required binaryArtifactStore,
              required binaryArtifactFallback,
              required swiftPmArtifactJunctionCapability,
              required packageLocalArtifactJunctionCapability,
              required dependencies,
            }) async => pinned;
      }
    }

    for (final plugin in plugins) {
      final packageAlias = p.join(packagesDir, plugin.name);
      pluginPackageDirs[plugin.name] = await pluginOverlay.stagePluginPackage(
        alias: packageAlias,
        target: plugin.swiftPackageDir,
        platformDir: plugin.platformDirectoryName,
        vendorDir: shouldVendor ? resolvedVendorDir : null,
        packageTargets: pluginTargets,
        copySources: copyPluginPackages.contains(plugin.name),
        vendorNormalizationCache: vendorNormalizationCache,
        dependencyEvaluationCache: dependencyEvaluationCache,
        vendorCheckoutCache: vendorCheckoutCache,
        scratchPath: scratchPath,

        binaryArtifactStore: binaryArtifactStore,
        binaryArtifactFallback: binaryArtifactFallback,
        swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
        packageLocalArtifactJunctionCapability:
            packageLocalArtifactJunctionCapability,
        evaluateDependencyRefs: pluginRefEvaluator,
        clonePackage: clonePackage,
      );
    }
    if (shouldVendor &&
        binaryArtifactStore != null &&
        binaryArtifactFallback != null) {
      await dependencyPreparation.prepareArtifacts(
        resolvedVendorDir,
        binaryArtifactStore,
        binaryArtifactFallback,
        capability: packageLocalArtifactJunctionCapability,
      );
    }
    final packagesByDirectoryName = {
      for (final package in pluginPackageDirs.values)
        p.basename(package): package,
    };
    for (final plugin in plugins) {
      if (!shouldVendor && !copyPluginPackages.contains(plugin.name)) continue;
      final stagedPackage = pluginPackageDirs[plugin.name]!;
      final manifestFile = artifactFileSystem.file(
        p.join(stagedPackage, 'Package.swift'),
      );
      var manifest = await manifestFile.readAsString();
      final original = manifest;
      for (final call in SwiftPmManifestLexer.swiftCalls(
        manifest,
        '.package',
      ).reversed) {
        final dependencyPath = SwiftPmManifestLexer.namedString(
          call.text,
          'path',
        );
        if (dependencyPath == null) continue;
        final dependencyName =
            SwiftPmManifestLexer.namedString(call.text, 'name') ??
            p.basename(dependencyPath);
        final sharedPackage = packagesByDirectoryName[dependencyName];
        if (sharedPackage == null || p.equals(dependencyPath, sharedPackage)) {
          continue;
        }
        final rewritten = call.text.replaceFirst(
          RegExp(r'path\s*:\s*"[^"]+"'),
          'path: "${SwiftPmFilesystem.swiftPath(sharedPackage)}"',
        );
        manifest = manifest.replaceRange(call.start, call.end, rewritten);
      }
      if (manifest != original) {
        await filesystem.writeStable(manifestFile.path, manifest);
      }
    }
    await writePluginsPackage(
      pluginsDir: pluginsDir,
      frameworkDir: frameworkDir,
      plugins: plugins,
      pluginPackageDirs: pluginPackageDirs,
      deploymentTarget: deploymentTarget,
      verbose: verbose,
    );
  }

  Future<Map<String, String>?> resolveUnifiedDependencyRefs({
    required String resolveRoot,
    required Iterable<String> packageDirectories,
    required Future<Map<String, String>> Function(
      String packageDirectory,
      List<SwiftPmPackageDependency> dependencies,
    )
    evaluate,
    int maxRounds = 5,
  }) async {
    final dependencies = <String, SwiftPmPackageDependency>{};
    for (final directory in packageDirectories) {
      final manifest = artifactFileSystem.file(
        p.join(directory, 'Package.swift'),
      );
      if (!manifest.existsSync()) continue;
      for (final dep in SwiftPmManifestDependencies.parseUrlPackageDeps(
        await manifest.readAsString(),
      )) {
        dependencies.putIfAbsent(
          SwiftPmBinaryProvenance.canonicalGitUrl(dep.url),
          () => dep,
        );
      }
    }
    if (dependencies.isEmpty) return null;

    await artifactFileSystem.directory(resolveRoot).create(recursive: true);
    final hidden = <String, String>{};
    var refs = <String, String>{};
    for (var round = 0; round < maxRounds; round++) {
      await filesystem.writeStable(
        p.join(resolveRoot, 'Package.swift'),
        resolveManifest(packageDirectories, hidden.values),
      );
      refs = await evaluate(resolveRoot, dependencies.values.toList());
      final discovered = await hiddenDependencyCalls(
        p.join(resolveRoot, '.build', 'checkouts'),
        refs: refs,
        dependencies: dependencies,
        declared: hidden.keys.toSet(),
      );
      if (discovered.isEmpty) break;
      hidden.addAll(discovered);
    }
    return refs;
  }

  String resolveManifest(
    Iterable<String> packageDirectories,
    Iterable<String> hiddenDependencies,
  ) {
    final buffer = StringBuffer()
      ..writeln('// swift-tools-version: 5.9')
      ..writeln('import PackageDescription')
      ..writeln()
      ..writeln('let package = Package(')
      ..writeln('    name: "XcrossResolve",')
      ..writeln('    dependencies: [');
    for (final directory in packageDirectories) {
      buffer.writeln(
        '        .package(path: "${SwiftPmFilesystem.swiftPath(directory)}"),',
      );
    }
    for (final call in hiddenDependencies) {
      buffer.writeln('        $call,');
    }
    buffer
      ..writeln('    ]')
      ..writeln(')');
    return buffer.toString();
  }

  /// `.package(url:)` calls, keyed by package identity, re-declaring URL deps
  /// of resolved checkouts under [checkoutsDir] that [refs] does not pin. A
  /// checkout with any unpinned dep contributes all its URL deps so its
  /// version constraints take part in the unified resolution; identities
  /// already in [declared] keep their first declaration.
  Future<Map<String, String>> hiddenDependencyCalls(
    String checkoutsDir, {
    required Map<String, String> refs,
    required Map<String, SwiftPmPackageDependency> dependencies,
    required Set<String> declared,
  }) async {
    final result = <String, String>{};
    final checkouts = artifactFileSystem.directory(checkoutsDir);
    if (!checkouts.existsSync()) return result;
    // Checkouts left behind by earlier builds must not feed constraints in.
    final pinned = {
      for (final url in refs.keys)
        SwiftPmManifestDependencies.packageIdentityFromUrl(url).toLowerCase(),
    };
    final entries = checkouts.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final checkout in entries) {
      if (checkout is! Directory ||
          !pinned.contains(p.basename(checkout.path).toLowerCase())) {
        continue;
      }
      final manifestFile = artifactFileSystem.file(
        p.join(checkout.path, 'Package.swift'),
      );
      if (!manifestFile.existsSync()) continue;
      final manifest = sourceNormalizer.normalizeHostManifest(
        await manifestFile.readAsString(),
      );
      final deps = SwiftPmManifestDependencies.parseUrlPackageDeps(manifest);
      final unpinned = deps.where(
        (dep) =>
            !refs.containsKey(SwiftPmBinaryProvenance.canonicalGitUrl(dep.url)),
      );
      if (unpinned.isEmpty ||
          unpinned.every(
            (dep) => dependencies.containsKey(
              SwiftPmBinaryProvenance.canonicalGitUrl(dep.url),
            ),
          )) {
        continue;
      }
      for (final dep in deps) {
        final identity = SwiftPmManifestDependencies.packageIdentityFromUrl(
          dep.url,
        ).toLowerCase();
        if (declared.contains(identity)) continue;
        final call = standaloneDependencyCall(dep, manifest);
        if (call == null) continue;
        // One entry per identity: firebase declares each helper dep twice
        // (a CI-only `branch:` variant and the released range) and SwiftPM
        // rejects duplicate identities in a manifest. Prefer the range.
        final existing = result[identity];
        if (existing == null || isBranchRequirement(existing)) {
          result[identity] = call;
        }
        dependencies.putIfAbsent(
          SwiftPmBinaryProvenance.canonicalGitUrl(dep.url),
          () => dep,
        );
      }
    }
    return result;
  }

  bool isBranchRequirement(String call) =>
      RegExp(r'\bbranch\s*:').hasMatch(call);

  /// `.package(url: "<literal>", <requirement>)` for [dep] that compiles on
  /// its own, or null when the requirement references manifest state that
  /// cannot be carried over (e.g. firebase's `packageInfo.range` tuples).
  /// String constants the requirement uses are inlined as literals.
  String? standaloneDependencyCall(
    SwiftPmPackageDependency dep,
    String manifest,
  ) {
    final open = dep.match.indexOf('(');
    var inner = dep.match.substring(open + 1, dep.match.length - 1);
    inner = inner
        .replaceFirst(RegExp(r'name:\s*"[^"]*"\s*,\s*'), '')
        .replaceFirst(
          RegExp(r'url:\s*(?:"[^"]+"|[A-Za-z_]\w*)'),
          'url: "${dep.url}"',
        );
    final constants = SwiftPmManifestLexer.manifestStringConstants(manifest);
    final code = inner.replaceAll(RegExp(r'"(?:[^"\\]|\\.)*"'), '""');
    final identifier = RegExp(r'\.?\b[A-Za-z_]\w*(?<label>\s*:)?');
    final substitutions = <String, String>{};
    for (final match in identifier.allMatches(code)) {
      if (match.namedGroup('label') != null) continue;
      final token = match.group(0)!;
      if (token.startsWith('.')) continue;
      if (_dependencyCallIdentifiers.contains(token)) continue;
      final value = constants[token];
      if (value == null) return null;
      substitutions[token] = value;
    }
    for (final entry in substitutions.entries) {
      inner = inner.replaceAll(
        RegExp('(?<![\\w."])${entry.key}(?![\\w"])'),
        '"${entry.value}"',
      );
    }
    return '.package(${inner.replaceAll(RegExp(r'\s+'), ' ').trim()})';
  }

  /// Writes `FlutterFramework/Package.swift` and links or copies the real
  /// [flutterXcframework]. Windows copies because creating symlinks commonly
  /// requires Developer Mode or elevation.
  Future<void> writeFlutterFrameworkPackage({
    required String frameworkDir,
    required String flutterXcframework,
    required bool? copyFlutterXcframework,
  }) async {
    await artifactFileSystem.directory(frameworkDir).create(recursive: true);
    await filesystem.writeStable(
      p.join(frameworkDir, 'Package.swift'),
      SwiftPmManifest.flutterFrameworkManifest(),
    );

    final frameworkPath = p.join(frameworkDir, 'Flutter.xcframework');
    await hostBuildServices.stageFlutterFramework(
      flutterXcframework,
      frameworkPath,
      copy: copyFlutterXcframework,
    );
  }

  /// Writes `Plugins/Package.swift` and the generated registrant source.
  Future<void> writePluginsPackage({
    required String pluginsDir,
    required String frameworkDir,
    required List<IosPlugin> plugins,
    required Map<String, String> pluginPackageDirs,
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
  }) async {
    final sourcesDir = p.join(pluginsDir, 'Sources', pluginsProductName);
    await artifactFileSystem.directory(sourcesDir).create(recursive: true);

    await filesystem.writeStable(
      p.join(pluginsDir, 'Package.swift'),
      SwiftPmManifest.pluginsManifest(
        plugins,
        frameworkDir,
        pluginPackageDirs: pluginPackageDirs,
        deploymentTarget: deploymentTarget,
      ),
    );

    await filesystem.writeStable(
      p.join(sourcesDir, 'GeneratedPluginRegistrant.swift'),
      manifest.registrantSource(
        plugins,
        verbose: verbose,
        stagedPackageDirs: pluginPackageDirs,
      ),
    );
  }
}

typedef SwiftPmSourceTransform =
    String Function(String content)? Function(String path);
