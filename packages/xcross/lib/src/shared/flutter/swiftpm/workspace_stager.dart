import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmWorkspaceStager<T extends PlatformHostInterface> {
  SwiftPmWorkspaceStager(this.runtime);
  final SwiftPmRuntime<T> runtime;

  /// Package-root entries a plugin's iOS SwiftPM build can never reach:
  /// Dart code, other platforms, development trees, and pub metadata.
  ///
  /// This is a sparse checkout by exclusion rather than inclusion because
  /// the reachable remainder has no fixed shape: published plugins refer
  /// to arbitrary sibling directories from their iOS package (`../../src`
  /// sources, `../../include` header search paths, shared `darwin/`
  /// trees), so only the provably unreachable entries are skipped.
  static const _iosUnreachableEntries = {
    // development trees
    '.dart_tool',
    '.git',
    '.github',
    'build',
    'example',
    'test',
    'tests',
    // dart code and pub metadata
    'lib',
    'pubspec.yaml',
    'pubspec.lock',
    'analysis_options.yaml',
    'readme.md',
    'changelog.md',
    // other platforms ('darwin' stays: it is shared with iOS)
    'android',
    'macos',
    'windows',
    'linux',
    'web',
    // pigeon input definitions: consumed by the pigeon generator at
    // development time, never referenced by the generated iOS build
    'pigeons',
  };

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

    await Directory(packagesDir).create(recursive: true);
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
          await stagePluginPackage(
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
      final bootstrap = await runtime.hostPolicy.bootstrapPinnedDependencies(
        runtime,
        prestaged,
        resolvedVendorDir,
        clonePackage,
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
              : runtime.binaryRecovery.evaluatedDependencyRefs(
                  directory,
                  runtime.runner.locateTool,

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
          await runtime.filesystem.writeStable(entry.key, entry.value);
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
      pluginPackageDirs[plugin.name] = await stagePluginPackage(
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
      await runtime.hostPolicy.prepareBinaryArtifacts(
        runtime,
        resolvedVendorDir,
        binaryArtifactStore,
        binaryArtifactFallback,
        packageLocalArtifactJunctionCapability,
      );
    }
    final packagesByDirectoryName = {
      for (final package in pluginPackageDirs.values)
        p.basename(package): package,
    };
    for (final plugin in plugins) {
      if (!shouldVendor && !copyPluginPackages.contains(plugin.name)) continue;
      final stagedPackage = pluginPackageDirs[plugin.name]!;
      final manifestFile = File(p.join(stagedPackage, 'Package.swift'));
      var manifest = await manifestFile.readAsString();
      final original = manifest;
      for (final call in SwiftPmManifest.swiftCalls(
        manifest,
        '.package',
      ).reversed) {
        final dependencyPath = SwiftPmManifest.namedString(call.text, 'path');
        if (dependencyPath == null) continue;
        final dependencyName =
            SwiftPmManifest.namedString(call.text, 'name') ??
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
        await runtime.filesystem.writeStable(manifestFile.path, manifest);
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

  /// SwiftPM evaluates remote manifests before checkout normalization can fix
  /// host-incompatible declarations. Prestage deterministically pinned Git
  /// dependencies through normalized local checkouts for the resolve pass,
  /// then restore the original plugin manifests for normal vendoring. Leave
  /// version ranges to SwiftPM's solver rather than choosing a version here.
  Future<({Map<String, String> pins, Map<String, String> originals})>
  bootstrapWindowsPinnedDependencyResolve(
    Iterable<String> packageDirectories,
    String vendorDir, {
    Future<void> Function(
      String git,
      String url,
      String ref,
      String destination,
    )?
    clonePackage,
  }) async {
    final originals = <String, String>{};
    final rewrites = <String, String>{};
    final pins = <String, String>{};
    final replacements = <String, String>{};
    final manifests = <String, String>{};
    final urls = <String, String>{};
    final products = <String, Set<String>>{};
    final unpinned = <String>{};
    String? git;
    for (final directory in packageDirectories) {
      final manifestFile = File(p.join(directory, 'Package.swift'));
      if (!manifestFile.existsSync()) continue;
      final original = await manifestFile.readAsString();
      manifests[manifestFile.path] = original;
      for (final dependency in SwiftPmManifest.parseUrlPackageDeps(original)) {
        final identity = SwiftPmBinaryRecovery.canonicalGitUrl(dependency.url);
        final ref = RegExp(
          r'\b(?:exact|revision)\s*:\s*"([^"\r\n]+)"',
        ).firstMatch(dependency.match)?[1];
        if (ref == null) {
          unpinned.add(identity);
          continue;
        }
        final previousRef = pins[identity];
        if (previousRef != null && previousRef != ref) {
          throw FlutterBuildError(
            'Conflicting pinned refs for $identity: $previousRef and $ref',
          );
        }
        pins[identity] = ref;
        urls.putIfAbsent(identity, () => dependency.url);
        products
            .putIfAbsent(identity, () => <String>{})
            .addAll(
              SwiftPmManifest.consumedProducts(original, dependency.identity),
            );
      }
    }
    // A range for the same URL must continue through SwiftPM's solver.
    for (final identity in unpinned) {
      pins.remove(identity);
      urls.remove(identity);
      products.remove(identity);
    }
    for (final entry in pins.entries) {
      final identity = entry.key;
      final ref = entry.value;
      final url = urls[identity]!;
      final destination = p.join(
        vendorDir,
        SwiftPmManifest.vendorPackageDirName(url, ref),
      );
      git ??= await runtime.runner.locateTool('git');
      await (clonePackage ?? runtime.checkout.cloneGitPackage)(
        git,
        url,
        ref,
        destination,
      );
      await runtime.checkout.normalizeVendoredPackageManifests(
        destination,
        consumedProducts: products[identity]!,
      );
      replacements[identity] = destination;
    }
    for (final entry in manifests.entries) {
      var rewritten = entry.value;
      for (final dependency in SwiftPmManifest.parseUrlPackageDeps(
        entry.value,
      )) {
        final identity = SwiftPmBinaryRecovery.canonicalGitUrl(dependency.url);
        if (!replacements.containsKey(identity)) continue;
        rewritten = rewritten.replaceAll(
          dependency.match,
          '.package(name: "${dependency.identity}", '
          'path: "${SwiftPmFilesystem.swiftPath(replacements[identity]!)}")',
        );
      }
      if (rewritten != entry.value) {
        originals[entry.key] = entry.value;
        rewrites[entry.key] = rewritten;
      }
    }
    try {
      for (final entry in rewrites.entries) {
        await runtime.filesystem.writeStable(entry.key, entry.value);
      }
    } on Object {
      for (final entry in originals.entries) {
        await runtime.filesystem.writeStable(entry.key, entry.value);
      }
      rethrow;
    }
    return (pins: pins, originals: originals);
  }

  /// Pins every URL dependency reachable from [packageDirectories] with a
  /// single `swift package resolve`, so each package identity maps to exactly
  /// one revision across the whole plugin graph. Returns null when nothing
  /// declares a URL dependency.
  ///
  /// SwiftPM only sees dependencies a checkout's manifest declares for the
  /// host, so entries firebase-ios-sdk hides behind `#if os(macOS)` are never
  /// pinned. Each round scans the resolved checkouts for such unpinned deps,
  /// re-declares them on the resolve root (root dependencies are the only
  /// ones SwiftPM never prunes as unused), and resolves again until the pins
  /// cover the graph.
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
      final manifest = File(p.join(directory, 'Package.swift'));
      if (!manifest.existsSync()) continue;
      for (final dep in SwiftPmManifest.parseUrlPackageDeps(
        await manifest.readAsString(),
      )) {
        dependencies.putIfAbsent(
          SwiftPmBinaryRecovery.canonicalGitUrl(dep.url),
          () => dep,
        );
      }
    }
    if (dependencies.isEmpty) return null;

    await Directory(resolveRoot).create(recursive: true);
    final hidden = <String, String>{};
    var refs = <String, String>{};
    for (var round = 0; round < maxRounds; round++) {
      await runtime.filesystem.writeStable(
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
    final checkouts = Directory(checkoutsDir);
    if (!checkouts.existsSync()) return result;
    // Checkouts left behind by earlier builds must not feed constraints in.
    final pinned = {
      for (final url in refs.keys)
        SwiftPmManifest.packageIdentityFromUrl(url).toLowerCase(),
    };
    final entries = checkouts.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final checkout in entries) {
      if (checkout is! Directory ||
          !pinned.contains(p.basename(checkout.path).toLowerCase())) {
        continue;
      }
      final manifestFile = File(p.join(checkout.path, 'Package.swift'));
      if (!manifestFile.existsSync()) continue;
      final manifest = runtime.manifest.normalizeHostManifest(
        await manifestFile.readAsString(),
      );
      final deps = SwiftPmManifest.parseUrlPackageDeps(manifest);
      final unpinned = deps.where(
        (dep) =>
            !refs.containsKey(SwiftPmBinaryRecovery.canonicalGitUrl(dep.url)),
      );
      if (unpinned.isEmpty ||
          unpinned.every(
            (dep) => dependencies.containsKey(
              SwiftPmBinaryRecovery.canonicalGitUrl(dep.url),
            ),
          )) {
        continue;
      }
      for (final dep in deps) {
        final identity = SwiftPmManifest.packageIdentityFromUrl(
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
          SwiftPmBinaryRecovery.canonicalGitUrl(dep.url),
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
    final constants = SwiftPmManifest.manifestStringConstants(manifest);
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

  /// Stages [target] at [alias], using a shallow overlay when the Swift
  /// manifest needs host fixes (linker flags, Windows CRT imports) or when
  /// remote URL dependencies are vendored to path deps.
  ///
  /// [platformDir] is the package-root subdirectory [target] sits in — `ios`
  /// normally, `darwin` for shared-source Apple plugins. The staged tree keeps
  /// the same shape so relative paths inside the plugin's `Package.swift`
  /// (`../../src`, shared header search paths) still resolve.
  Future<String> stagePluginPackage({
    required String alias,
    required String target,
    String platformDir = 'ios',
    String? vendorDir,
    Map<String, String> packageTargets = const {},
    bool copySources = false,
    Map<String, Map<String, List<String>>>? vendorNormalizationCache,
    Map<String, Future<Map<String, String>>>? dependencyEvaluationCache,
    Map<String, Future<void>>? vendorCheckoutCache,
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
    var stagedPackage = alias;
    final shouldCopySources = vendorDir != null || copySources;
    if (shouldCopySources) {
      await runtime.filesystem.deleteUnless(
        alias,
        FileSystemEntityType.directory,
      );
      final packageRoot = p.dirname(p.dirname(target));
      await stageAncestorOverlay(
        sourceRoot: packageRoot,
        destinationRoot: alias,
        packageName: p.basename(target),
        platformDir: platformDir,
      );
      await runtime.filesystem.createDirectoryAlias(
        p.join(alias, platformDir, flutterFrameworkPackageName),
        p.join(p.dirname(alias), flutterFrameworkPackageName),
      );
      stagedPackage = p.join(alias, platformDir, p.basename(target));
    }

    final manifest = await File(p.join(target, 'Package.swift')).readAsString();
    var normalizedManifest = SwiftPmManifest.removeMissingResources(
      runtime.manifest.normalizeHostManifest(manifest),
      target,
    );
    for (final call in SwiftPmManifest.swiftCalls(
      normalizedManifest,
      '.package',
    ).reversed) {
      final relativePath = SwiftPmManifest.namedString(call.text, 'path');
      if (relativePath == null || p.isAbsolute(relativePath)) continue;
      final dependencyName =
          SwiftPmManifest.namedString(call.text, 'name') ??
          p.basename(relativePath);
      final targetPath = packageTargets[dependencyName];
      if (targetPath == null) continue;
      final rewritten = call.text.replaceFirst(
        RegExp(r'path\s*:\s*"[^"]+"'),
        'path: "${SwiftPmFilesystem.swiftPath(targetPath)}"',
      );
      normalizedManifest = normalizedManifest.replaceRange(
        call.start,
        call.end,
        rewritten,
      );
    }
    final fallbackSwiftModules = <String, List<String>>{};
    if (vendorDir != null) {
      await mirrorPluginPackage(target, stagedPackage, normalizedManifest);
      normalizedManifest = await runtime.dependencyVendor
          .vendorUrlPackagesAsPathDeps(
            normalizedManifest,

            vendorDir: vendorDir,
            packageDirectory: stagedPackage,
            fallbackSwiftModules: fallbackSwiftModules,
            normalizationCache: vendorNormalizationCache,
            evaluationCache: dependencyEvaluationCache,
            checkoutCache: vendorCheckoutCache,
            scratchPath: scratchPath,

            binaryArtifactStore: binaryArtifactStore,
            binaryArtifactFallback: binaryArtifactFallback,
            swiftPmArtifactJunctionCapability:
                swiftPmArtifactJunctionCapability,
            packageLocalArtifactJunctionCapability:
                packageLocalArtifactJunctionCapability,
            scopedDependencyRefEvaluator: evaluateDependencyRefs,
            clonePackage: clonePackage,
          );
    }

    if (shouldCopySources) {
      // Normalizing during the mirror keeps re-runs byte-stable: copying
      // first and normalizing after would rewrite (and re-timestamp) every
      // normalized source on every build.
      await mirrorPluginPackage(
        target,
        stagedPackage,
        normalizedManifest,
        transform: hostSwiftTransform(fallbackSwiftModules),
      );
    } else if (normalizedManifest == manifest) {
      await runtime.filesystem.createDirectoryAlias(stagedPackage, target);
      await runtime.manifest.normalizeHostSwiftTree(
        stagedPackage,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    } else {
      await overlayPluginManifest(target, stagedPackage, normalizedManifest);
      await runtime.manifest.normalizeHostSwiftTree(
        stagedPackage,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    }
    if (binaryArtifactStore != null && binaryArtifactFallback != null) {
      await runtime.binaryRecovery.prepareSupportedBinaryArtifacts(
        packageRoot: stagedPackage,
        binaryArtifactStore: binaryArtifactStore,
        binaryArtifactFallback: binaryArtifactFallback,
        packageLocalArtifactJunctionCapability:
            packageLocalArtifactJunctionCapability,
      );
    }

    return stagedPackage;
  }

  /// Mirrors [target] at [staged] with [manifest] as its `Package.swift`.
  ///
  /// Only differing files are rewritten, so a rebuild presents SwiftPM with
  /// the timestamps it already compiled and its incremental state stays
  /// warm.
  Future<void> mirrorPluginPackage(
    String target,
    String staged,
    String manifest, {
    SwiftPmSourceTransform? transform,
  }) async {
    await runtime.filesystem.deleteUnless(
      staged,
      FileSystemEntityType.directory,
    );
    await runtime.filesystem.syncDirectory(
      target,
      staged,
      preserve: const {'Package.swift'},
      transform: transform,
    );
    await runtime.filesystem.writeStable(
      p.join(staged, 'Package.swift'),
      manifest,
    );
    // The manifest is regenerated from the plugin's own each build and can
    // legitimately differ between the staging write and a later pass, so
    // "write only when changed" cannot keep its timestamp fixed on its own.
    // SwiftPM invalidates a package's whole target set on its manifest
    // timestamp, so stamp by content: identical output keeps the timestamp
    // SwiftPM already compiled against.
    await runtime.filesystem.stampByContent(
      p.join(staged, 'Package.swift'),
      manifest,
    );
  }

  /// The host-compatibility source rewrite as a sync transform, electing
  /// Swift sources but never package manifests or binary files.
  SwiftPmSourceTransform hostSwiftTransform(
    Map<String, List<String>> fallbackSwiftModules,
  ) => (path) {
    final name = p.basename(path);
    final isManifest =
        name == 'Package.swift' ||
        (name.startsWith('Package@') && name.endsWith('.swift'));
    if (p.extension(name) != '.swift' || isManifest) return null;
    return (content) => SwiftPmManifest.normalizeHostSwiftSource(
      content,
      fallbackSwiftModules: fallbackSwiftModules,
    );
  };

  /// Stages [target] at [staged] as per-entry aliases beneath a rewritten
  /// `Package.swift`, for hosts where symbolic links are first-class.
  Future<void> overlayPluginManifest(
    String target,
    String staged,
    String manifest,
  ) async {
    await runtime.filesystem.deleteEntity(staged);
    await Directory(staged).create(recursive: true);
    await runtime.filesystem.writeStable(
      p.join(staged, 'Package.swift'),
      manifest,
    );
    await for (final entity in Directory(target).list(followLinks: false)) {
      if (p.basename(entity.path) == 'Package.swift') continue;
      await stageEntity(
        entity,
        p.join(staged, p.basename(entity.path)),
        copyDirectories: false,
      );
    }
  }

  Future<void> stageAncestorOverlay({
    required String sourceRoot,
    required String destinationRoot,
    required String packageName,
    String platformDir = 'ios',
  }) async {
    await Directory(
      p.join(destinationRoot, platformDir),
    ).create(recursive: true);
    final staged = <String>{platformDir};
    await for (final entity in Directory(sourceRoot).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == platformDir ||
          _iosUnreachableEntries.contains(name.toLowerCase())) {
        continue;
      }
      staged.add(name);
      await stageEntity(
        entity,
        p.join(destinationRoot, name),
        copyDirectories: true,
        excludedSourcePath: destinationRoot,
      );
    }
    await pruneUnexpected(destinationRoot, staged);

    final stagedIos = <String>{packageName, flutterFrameworkPackageName};
    await for (final entity in Directory(
      p.join(sourceRoot, platformDir),
    ).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == packageName || name == flutterFrameworkPackageName) continue;
      stagedIos.add(name);
      await stageEntity(
        entity,
        p.join(destinationRoot, platformDir, name),
        copyDirectories: true,
        excludedSourcePath: destinationRoot,
      );
    }
    await pruneUnexpected(p.join(destinationRoot, platformDir), stagedIos);
  }

  /// Deletes entries of [directory] not named in [expected], so previously
  /// staged files that no longer qualify do not linger in the build tree.
  Future<void> pruneUnexpected(String directory, Set<String> expected) async {
    await for (final entity in Directory(directory).list(followLinks: false)) {
      if (!expected.contains(p.basename(entity.path))) {
        await runtime.filesystem.deleteEntity(entity.path);
      }
    }
  }

  Future<void> stageEntity(
    FileSystemEntity entity,
    String destination, {
    required bool copyDirectories,
    String? excludedSourcePath,
  }) async {
    final resolved = entity is Link
        ? entity.resolveSymbolicLinksSync()
        : entity.path;
    if (!Directory(resolved).existsSync()) {
      await runtime.filesystem.syncFile(File(resolved), destination);
    } else if (copyDirectories) {
      await runtime.filesystem.syncDirectory(
        resolved,
        destination,
        excludedSourcePath: excludedSourcePath,
      );
    } else {
      await runtime.filesystem.createDirectoryAlias(destination, resolved);
    }
  }

  /// Writes `FlutterFramework/Package.swift` and links or copies the real
  /// [flutterXcframework]. Windows copies because creating symlinks commonly
  /// requires Developer Mode or elevation.
  Future<void> writeFlutterFrameworkPackage({
    required String frameworkDir,
    required String flutterXcframework,
    required bool? copyFlutterXcframework,
  }) async {
    await Directory(frameworkDir).create(recursive: true);
    await runtime.filesystem.writeStable(
      p.join(frameworkDir, 'Package.swift'),
      SwiftPmManifest.flutterFrameworkManifest(),
    );

    final frameworkPath = p.join(frameworkDir, 'Flutter.xcframework');
    await runtime.hostPolicy.stageFlutterFramework(runtime, flutterXcframework, frameworkPath, copy: copyFlutterXcframework);
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
    await Directory(sourcesDir).create(recursive: true);

    await runtime.filesystem.writeStable(
      p.join(pluginsDir, 'Package.swift'),
      SwiftPmManifest.pluginsManifest(
        plugins,
        frameworkDir,
        pluginPackageDirs: pluginPackageDirs,
        deploymentTarget: deploymentTarget,
      ),
    );

    await runtime.filesystem.writeStable(
      p.join(sourcesDir, 'GeneratedPluginRegistrant.swift'),
      runtime.manifest.registrantSource(
        plugins,
        verbose: verbose,
        stagedPackageDirs: pluginPackageDirs,
      ),
    );
  }
}

typedef SwiftPmSourceTransform =
    String Function(String content)? Function(String path);
