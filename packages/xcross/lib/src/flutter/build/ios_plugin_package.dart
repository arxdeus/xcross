import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/flutter/build/preview_macro_stub_source.dart';
import 'package:xcross/src/flutter/build/swift_package_host_patches.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Name of the synthetic package/product/binary-target that wraps the real
/// `Flutter.xcframework` as a SwiftPM binary target (SwiftPM binary-target
/// paths must be relative to their own package, so the framework can't be
/// referenced directly from the aggregate plugins package). Mirrors
/// flutter_tools' own `kFlutterGeneratedFrameworkSwiftPackageTargetName`.
const String _flutterFrameworkPackageName = 'FlutterFramework';

/// Name of our aggregate package/product/target that pulls in every SPM
/// plugin's native code.
const String _pluginsProductName = 'FlutterPluginsGenerated';

/// Result of building the aggregate Flutter-plugins Swift package.
typedef SwiftPmDependencyRefEvaluator =
    Future<Map<String, String>> Function(
      String packageDirectory, {
      required String? scratchPath,
      required String? binaryArtifactStore,
      required String? binaryArtifactFallback,
      required bool swiftPmArtifactJunctionCapability,
      required bool packageLocalArtifactJunctionCapability,
      required List<SwiftPmPackageDependency> dependencies,
    });

typedef PrepareSwiftPmBinaryArtifact =
    Future<SwiftPmPreparedBinaryArtifact> Function(
      SwiftPmRemoteBinaryTarget target,
    );
typedef CreateSwiftPmBinaryAlias =
    Future<void> Function({required String alias, required String target});
typedef MaterializeSwiftPmBinaryArtifact =
    Future<SwiftPmBinaryArtifactPublication> Function({
      required String source,
      required String destination,
    });

final class SwiftPmPackageDependency {
  const SwiftPmPackageDependency({
    required this.name,
    required this.url,
    required this.identity,
    required this.match,
  });

  final String? name;
  final String url;
  final String identity;
  final String match;
}

final class SwiftPmBinaryArtifactProvenance {
  const SwiftPmBinaryArtifactProvenance({
    required this.packageIdentity,
    required this.target,
    required this.manifestPath,
  });

  final String packageIdentity;
  final SwiftPmRemoteBinaryTarget target;
  final String manifestPath;
}

final class SwiftPmBinaryAttemptState {
  final Set<String> bootstrapRecovered = {};
  final Set<String> finalRecovered = {};
  final Set<String> copied = {};
}

final class GeneratedPluginsBuildResult {
  /// Creates a result wrapping the built dylib paths.
  const GeneratedPluginsBuildResult({
    required this.libraryPath,
    required this.dylibPaths,
    required this.modulesDir,
  });

  /// Absolute path to the built `libFlutterPluginsGenerated.dylib`.
  final String libraryPath;

  /// Absolute paths to every dynamic library produced by SwiftPM.
  final List<String> dylibPaths;

  /// Absolute path to SwiftPM's `Modules` directory holding the built
  /// `.swiftmodule` files, or null when SwiftPM did not emit one. App
  /// extensions that `import` a plugin module compile against this.
  final String? modulesDir;
}

/// Synthesizes and builds a Swift Package Manager package that aggregates
/// every Flutter plugin's iOS SPM native code into one dynamic library,
/// cross-compiled on Linux or Windows via a Darwin-SDK-backed `swift build
/// --swift-sdk`.
///
/// Mirrors Flutter's own SPM plugin integration: a generated wrapper package
/// depending on every plugin package plus a `FlutterFramework` binary-target
/// wrapper around `Flutter.xcframework`. Two deliberate differences from
/// Flutter's tool: `.package(path:)` entries use absolute paths (there is no
/// committed Xcode project here to keep portable), and the aggregate is a
/// *dynamic* library, so its produced dylibs can be embedded under
/// `Frameworks` and Runner can link only the aggregate instead of hand-deriving
/// Swift-runtime autolink flags for a static library.
typedef ArtifactJunctionCapabilityResolver =
    Future<({bool swiftPmArtifact, bool packageLocalArtifact})> Function();

abstract final class GeneratedPluginsPackage {
  /// Builds the aggregate dylib for the subset of [plugins] that use Swift
  /// Package Manager. Returns null if there is nothing to build.
  ///
  /// [projectRoot]        — Flutter project root (logging context only).
  /// [flutterXcframework] — Path to the real `Flutter.xcframework` (from
  ///                         `IosEngineCache.flutterXcframework`).
  /// [workspace] owns the stable generated-package, scratch, and vendored
  /// dependency directories reused between builds.
  static Future<GeneratedPluginsBuildResult?> build({
    required String projectRoot,
    required SwiftPmWorkspace workspace,
    required List<IosPlugin> plugins,
    required String flutterXcframework,
    required IosDeploymentTarget deploymentTarget,
    bool verbose = false,
    String? toolchainIdentity,
    String? sdkIdentity,
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
    ArtifactJunctionCapabilityResolver? artifactJunctionCapabilityResolver,
    SwiftPmDependencyRefEvaluator? evaluateDependencyRefs,
    Future<void> Function(
      String git,
      String url,
      String ref,
      String destination,
    )?
    clonePackage,
  }) =>
      Log.logStep('Building Flutter plugins (Swift Package Manager)', () async {
        final outputDir = workspace.packages;
        final spmPlugins = plugins
            .where((plugin) => plugin.usesSwiftPackageManager)
            .toList();
        if (spmPlugins.isEmpty) return null;
        final capabilities =
            await artifactJunctionCapabilityResolver?.call() ??
            (
              swiftPmArtifact: swiftPmArtifactJunctionCapability,
              packageLocalArtifact: packageLocalArtifactJunctionCapability,
            );

        Log.logTrace(
          'projectRoot=$projectRoot '
          'spmPlugins=${[for (final plugin in spmPlugins) plugin.name]}',
        );

        final targetDebugDir = p.join(
          workspace.scratch,
          'arm64-apple-ios',
          'debug',
        );
        final fingerprint = await incrementalBuildFingerprint(
          plugins: spmPlugins,
          flutterXcframework: flutterXcframework,
          deploymentTarget: deploymentTarget,
          verbose: verbose,
          toolchainIdentity: toolchainIdentity,
          sdkIdentity: sdkIdentity,
        );
        final fingerprintFile = File(
          p.join(outputDir, '.xcross-build-fingerprint'),
        );
        if (fingerprintFile.existsSync() &&
            await fingerprintFile.readAsString() == fingerprint &&
            File(
              p.join(targetDebugDir, 'lib$_pluginsProductName.dylib'),
            ).existsSync()) {
          Log.logTrace('reusing unchanged SwiftPM plugin build');
          return discoverAndRewriteDylibs(targetDebugDir);
        }
        final targetDirectory = Directory(targetDebugDir);
        if (targetDirectory.existsSync()) {
          await targetDirectory.delete(recursive: true);
        }

        final interopProductsByPlugin = <String, Set<String>>{};

        for (final plugin in spmPlugins) {
          final manifest = await File(
            p.join(plugin.swiftPackageDir, 'Package.swift'),
          ).readAsString();
          final products = dependencyProductNames(manifest);
          if (products.isNotEmpty) {
            interopProductsByPlugin[plugin.name] = products;
          }
        }
        final interopTargetCandidates = {
          for (final products in interopProductsByPlugin.values) ...products,
        };

        await writeGeneratedPackages(
          outputDir: outputDir,
          plugins: spmPlugins,
          flutterXcframework: flutterXcframework,
          copyFlutterXcframework: true,
          vendorDir: workspace.vendor,
          copyPluginPackages: spmPlugins.map((plugin) => plugin.name).toSet(),
          deploymentTarget: deploymentTarget,
          verbose: verbose,
          scratchPath: workspace.scratch,
          binaryArtifactStore: workspace.binaryArtifactStore,
          binaryArtifactFallback: workspace.binaryArtifactFallback,
          swiftPmArtifactJunctionCapability: capabilities.swiftPmArtifact,
          packageLocalArtifactJunctionCapability:
              capabilities.packageLocalArtifact,
          evaluateDependencyRefs: evaluateDependencyRefs,
          clonePackage: clonePackage,
        );

        final pluginsDir = p.join(outputDir, 'Plugins');
        final scratchPath = workspace.scratch;
        final stagedFlutterXcframework = p.join(
          outputDir,
          'Packages',
          _flutterFrameworkPackageName,
          'Flutter.xcframework',
        );
        await _runSwiftBuild(
          workspace: workspace,
          pluginsDir: pluginsDir,
          scratchPath: scratchPath,
          flutterXcframework: stagedFlutterXcframework,
          interopTargetCandidates: interopTargetCandidates,
          interopConsumers: {
            for (final plugin in spmPlugins)
              if (interopProductsByPlugin[plugin.name] case final products?)
                p.join(
                  outputDir,
                  'Packages',
                  plugin.name,
                  plugin.platformDirectoryName,
                  p.basename(plugin.swiftPackageDir),
                ): products,
          },
          swiftPmArtifactJunctionCapability: capabilities.swiftPmArtifact,
          packageLocalArtifactJunctionCapability:
              capabilities.packageLocalArtifact,
        );

        final result = await discoverAndRewriteDylibs(targetDebugDir);
        await _writeStable(fingerprintFile.path, fingerprint);
        return result;
      });

  @visibleForTesting
  static Future<String> incrementalBuildFingerprint({
    required List<IosPlugin> plugins,
    required String flutterXcframework,
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
    String? toolchainIdentity,
    String? sdkIdentity,
  }) async {
    Digest? result;
    final input = sha256.startChunkedConversion(
      ChunkedConversionSink.withCallback((digests) => result = digests.single),
    );

    void add(String value) {
      input.add(utf8.encode(value));
      input.add(const [0]);
    }

    add('xcross-swiftpm-build-v4');
    add(objectiveCLinkerSwiftDriverArguments.join('\u0001'));
    if (Platform.isLinux) {
      add(objectiveCSmallStubSwiftDriverArguments.join('\u0001'));
    }
    add(deploymentTarget.version);
    add(verbose.toString());
    final sdk = DarwinSdk.current();
    if (toolchainIdentity == null && sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run '
        '`xcross sdk install <Xcode.xip>` first.',
      );
    }
    final resolvedToolchainIdentity =
        toolchainIdentity ??
        jsonEncode(await resolveBuildToolchainIdentity(sdk!));
    add(resolvedToolchainIdentity);
    final resolvedSdkIdentity =
        sdkIdentity ??
        (sdk == null
            ? ''
            : jsonEncode(await SdkInstall.sdkBuildIdentity(sdk.swiftSdkPath)));
    add(resolvedSdkIdentity);

    Future<void> addTree(String root) async {
      final directory = Directory(root);
      if (!directory.existsSync()) {
        add('missing:$root');
        return;
      }
      final files = <File>[];
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) files.add(entity);
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        add(p.relative(file.path, from: root).replaceAll(r'\', '/'));
        input.add(await file.readAsBytes());
        input.add(const [0]);
      }
    }

    for (final plugin
        in plugins.toList()..sort((a, b) => a.name.compareTo(b.name))) {
      add(plugin.name);
      add(plugin.platformDirectoryName);
      await addTree(plugin.swiftPackageDir);
    }
    final frameworkFiles = <File>[];
    await for (final entity in Directory(
      flutterXcframework,
    ).list(recursive: true)) {
      if (entity is File) frameworkFiles.add(entity);
    }
    frameworkFiles.sort((a, b) => a.path.compareTo(b.path));
    for (final file in frameworkFiles) {
      final stat = file.statSync();
      add(
        p.relative(file.path, from: flutterXcframework).replaceAll(r'\', '/'),
      );
      add(stat.size.toString());
      add(stat.modified.microsecondsSinceEpoch.toString());
    }
    input.close();
    return result!.toString();
  }

  /// Cross-compiles the synthesized packages in [pluginsDir] with

  /// `swift build --swift-sdk arm64-apple-ios`.
  static Future<void> _runSwiftBuild({
    required SwiftPmWorkspace workspace,
    required String pluginsDir,
    required String scratchPath,
    required String flutterXcframework,
    required Set<String> interopTargetCandidates,
    required Map<String, Set<String>> interopConsumers,
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
  }) async {
    final outputDir = workspace.packages;
    final sdk = DarwinSdk.current();
    if (sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run '
        '`xcross sdk install <Xcode.xip>` first.',
      );
    }
    // The bundle only compiles against the toolchain it was patched with,
    // so say so up front instead of letting Swift fail per source file with
    // hundreds of "this SDK is not supported by the compiler" errors.
    final mismatch = await SdkInstall.hostToolchainMismatch(sdk.swiftSdkPath);
    if (mismatch != null) {
      throw FlutterBuildError(SdkInstall.mismatchGuidance(mismatch));
    }
    final swift = await ProcessRunner.locateTool('swift');
    final swiftPackage = Platform.isWindows
        ? await ProcessRunner.locateTool('swift-package')
        : swift;
    final swiftBuild = Platform.isWindows
        ? await ProcessRunner.locateTool('swift-build')
        : swift;

    // Real `Flutter.framework` (not our FlutterFramework binary-target
    // wrapper). Our own aggregate target resolves `import Flutter` via
    // that wrapper's declared package dependency, but individual
    // third-party plugin targets often don't declare any such dependency
    // in their own Package.swift at all — they rely on Xcode's implicit,
    // project-wide framework search paths to make `import Flutter` resolve
    // (verified against a real published plugin: its manifest lists zero
    // dependencies, yet its Swift source does `import Flutter`). A plain
    // `swift build` has no such implicit project-wide behaviour, so we
    // reproduce it ourselves with build-wide framework search flags. Swift
    // targets need `-Xswiftc -F`; C and Objective-C targets need the matching
    // `-Xcc -F` pair so imports such as `<Flutter/Flutter.h>` resolve too.
    final flutterFrameworkSlice = p.join(flutterXcframework, 'ios-arm64');
    final linker = await DarwinSdk.resolveLd64Lld(sdk);
    final windows = Platform.isWindows;
    final darwinClang = windows
        ? await DarwinSdk.resolveDarwinClang(sdk)
        : null;
    final toolsetPath = await writeToolset(
      outputDir: outputDir,
      linkerPath: linker,
      cCompilerPath: darwinClang,
      cxxCompilerPath: windows
          ? await DarwinSdk.resolveDarwinClang(sdk, name: 'clang++')
          : null,
    );
    // Apple's real `#Preview` macro plugin ships only inside Xcode, so no
    // cross host has it. The compiled stub answers the macro through
    // Swift's own `-load-plugin-executable` extension point instead — its
    // host compiler is whichever one built [darwinClang], available on
    // every host that can build this project at all.
    final previewMacroStub = await writePreviewMacroStub(
      outputDir: outputDir,
      cCompilerPath: darwinClang ?? await ProcessRunner.locateTool('cc'),
    );
    final objectiveCCompatibilityHeader =
        await writeObjectiveCCompatibilityHeader(outputDir);
    final swiftSdksPath = p.dirname(sdk.swiftSdkPath);
    final environment = swiftProcessEnvironment(windows: windows);
    if (windows) {
      await _resolveWindowsDependencies(
        swift: swiftPackage,
        pluginsDir: pluginsDir,
        scratchPath: scratchPath,
        swiftSdksPath: swiftSdksPath,
        toolsetPath: toolsetPath,
        vendorDir: workspace.vendor,
        binaryArtifactStore: workspace.binaryArtifactStore,
        binaryArtifactFallback: workspace.binaryArtifactFallback,
        swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
        packageLocalArtifactJunctionCapability:
            packageLocalArtifactJunctionCapability,
        environment: environment,
      );
    }
    final targetBuildDir = p.join(scratchPath, 'arm64-apple-ios', 'debug');
    Future<void> runBuild([List<String> selection = const []]) async {
      final arguments = <String>[
        ...swiftBuildArguments(
          pluginsDir: pluginsDir,
          scratchPath: scratchPath,
          swiftSdksPath: swiftSdksPath,
          iosSdk: sdk.iPhoneOSSdk(),
          flutterFrameworkSlice: flutterFrameworkSlice,
          objectiveCCompatibilityHeader: objectiveCCompatibilityHeader,
          toolsetPath: toolsetPath,
          linkerPath: windows ? null : linker,
          windows: windows,
          interopSearchPaths: swiftInteropSearchPaths(targetBuildDir),
          previewMacroStubPath: previewMacroStub,
        ),
        ...selection,
      ];

      if (windows) arguments.removeAt(0);
      Future<void> invoke() => ProcessRunner.runChecked(
        swiftBuild,
        arguments,
        environment: environment,
        inheritStdio: windows && Log.isVerbose,
        label: 'swift build',
      );
      await repairWindowsGeneratedBuildFiles(
        scratchPath,
        targetBuildDir,
        windows: windows,
      );
      try {
        await invoke();
      } on Object {
        if (!windows) rethrow;
        final repaired = await repairWindowsGeneratedBuildFiles(
          scratchPath,
          targetBuildDir,
          windows: true,
        );
        if (!repaired) rethrow;
        await invoke();
      }
      if (windows) {
        await repairWindowsGeneratedBuildFiles(
          scratchPath,
          targetBuildDir,
          windows: true,
        );
      }
    }

    await buildTranslatingSdkMismatch(
      () => buildWithInteropRecovery(
        build: runBuild,
        buildTarget: (target) => runBuild(['--target', target]),
        targetBuildDir: targetBuildDir,
        interopTargetCandidates: interopTargetCandidates,
        repairConsumers: () => repairSwiftInteropConsumers(
          targetBuildDir: targetBuildDir,
          consumerProducts: interopConsumers,
        ),
        windows: windows,
      ),
    );
  }

  @visibleForTesting
  static Future<bool> repairWindowsGeneratedBuildFiles(
    String scratchPath,
    String targetBuildDir, {
    bool? windows,
  }) async {
    if (!(windows ?? Platform.isWindows)) return false;
    final root = Directory(targetBuildDir);
    if (!root.existsSync()) return false;
    var changed = false;
    for (final json in [
      ...root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => p.extension(file.path) == '.json'),
      File(
        p.join(
          scratchPath,
          'x86_64-unknown-windows-msvc',
          'debug',
          'plugin-tools-description.json',
        ),
      ),
    ]) {
      if (!json.existsSync()) continue;
      final original = await json.readAsString();
      final normalized = original.replaceAll(r'\\\\?\\C:\\?\\C:\\', r'C:\\');
      if (normalized != original) {
        await json.writeAsString(normalized);
        changed = true;
      }
    }
    for (final accessor
        in root
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where(
              (file) => p.basename(file.path) == 'resource_bundle_accessor.m',
            )) {
      final original = await accessor.readAsString();
      final normalized = original
          .replaceAll(r'\', '/')
          .replaceAll(
            '#import <Foundation/Foundation.h>',
            '#include <Foundation/Foundation.h>',
          );
      if (normalized != original) {
        await accessor.writeAsString(normalized);
        changed = true;
      }
    }
    return changed;
  }

  /// Swift reports a toolchain/SDK ABI mismatch once per importing file and
  /// never names the cause a user can act on, so replace it with the one
  /// instruction that fixes it. A stamped bundle is caught before the build
  /// starts; this covers bundles installed by an older xcross, which carry
  /// no stamp to compare against.
  @visibleForTesting
  static Future<void> buildTranslatingSdkMismatch(
    Future<void> Function() build,
  ) async {
    try {
      await build();
    } on Object catch (error) {
      if (!'$error'.contains(swiftSdkMismatchMarker)) rethrow;
      throw FlutterBuildError(SdkInstall.mismatchGuidance(null));
    }
  }

  /// Resolves Windows dependencies with the external toolset, materializes
  /// the Git-for-Windows symlink placeholders the resolve leaves behind, and
  /// normalizes the resulting Swift sources for host compatibility.
  ///
  /// Order matters: resolution must run before the placeholders are
  /// materialized (see [materializeCheckoutSymlinks]'s own doc comment), and
  /// normalization must run after, since it rewrites the materialized
  /// sources, not the placeholders.
  static Future<void> _resolveWindowsDependencies({
    required String swift,
    required String pluginsDir,
    required String scratchPath,
    required String swiftSdksPath,
    required String toolsetPath,
    required String vendorDir,
    required String binaryArtifactStore,
    required String binaryArtifactFallback,
    required bool swiftPmArtifactJunctionCapability,
    required bool packageLocalArtifactJunctionCapability,
    required Map<String, String>? environment,
  }) async {
    Future<void> resolve() => ProcessRunner.runChecked(
      swift,
      swiftResolveArguments(
        pluginsDir: pluginsDir,
        scratchPath: scratchPath,
        swiftSdksPath: swiftSdksPath,
        toolsetPath: toolsetPath,
      ).skip(1).toList(),
      environment: environment,
      inheritStdio: Log.isVerbose,
      label: 'swift package resolve',
    );
    final attemptState = SwiftPmBinaryAttemptState();
    final packageIdentities = await _packageIdentitiesByDirectory(pluginsDir);
    Future<bool> recover() => stageExtractedBinaryArtifacts(
      scratchPath: scratchPath,
      vendorDir: vendorDir,
      packageIdentities: packageIdentities,
      binaryArtifactStore: binaryArtifactStore,
      binaryArtifactFallback: binaryArtifactFallback,
      attemptState: attemptState,
      packageLocalArtifactJunctionCapability:
          packageLocalArtifactJunctionCapability,
      windows: true,
    );
    await resolveWindowsDependencies(
      resolve: resolve,
      recoverBootstrap: recover,
      materialize: () => materializeCheckoutSymlinks(scratchPath),
      normalize: () => normalizeResolvedPackageManifests(scratchPath),
      recoverFinal: recover,
    );
  }

  @visibleForTesting
  static Future<void> resolveWindowsDependencies({
    required Future<void> Function() resolve,
    required Future<bool> Function() recoverBootstrap,
    required Future<bool> Function() materialize,
    required Future<bool> Function() normalize,
    required Future<bool> Function() recoverFinal,
  }) async {
    await resolveWithFinalBinaryRecovery(
      resolve: resolve,
      recover: recoverBootstrap,
    );
    final changed = await materialize() | await normalize();
    if (changed) {
      await resolveWithFinalBinaryRecovery(
        resolve: resolve,
        recover: recoverFinal,
      );
    }
  }

  @visibleForTesting
  static Future<void> prepareSupportedBinaryArtifacts({
    required String packageRoot,
    required String binaryArtifactStore,
    required String binaryArtifactFallback,
    required bool packageLocalArtifactJunctionCapability,
    PrepareSwiftPmBinaryArtifact? prepare,
    CreateSwiftPmBinaryAlias? createAlias,
    MaterializeSwiftPmBinaryArtifact? materialize,
    Future<void> Function(String alias)? removeAlias,
    Future<void> Function(String path, List<int> bytes)? writeManifest,
    bool? windows,
  }) async {
    if (!(windows ?? Platform.isWindows)) return;
    final root = Directory(_ioPath(packageRoot));
    if (!root.existsSync()) return;

    final store = SwiftPmBinaryArtifactStore(binaryArtifactStore);
    final preparer = SwiftPmBinaryArtifactPreparer(store: store);
    final runPrepare = prepare ?? preparer.prepare;
    final create = createAlias ?? preparer.createBinaryArtifactJunction;
    final copy = materialize ?? preparer.materializeBinaryArtifact;
    final remove = removeAlias ?? preparer.removeBinaryArtifactAlias;
    final write = writeManifest ?? _writeAtomic;
    final manifests = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) {
          final name = p.basename(file.path);
          return name == 'Package.swift' ||
              (name.startsWith('Package@') && name.endsWith('.swift'));
        });
    for (final manifestFile in manifests) {
      final original = await manifestFile.readAsString();
      final targets = SwiftPmBinaryTargetManifest.discover(original);
      if (targets.isEmpty) continue;
      final createdDestinations =
          <
            String,
            ({String source, SwiftPmBinaryArtifactPublication? publication})
          >{};
      final localPaths = <SwiftPmRemoteBinaryTarget, String>{};
      try {
        for (final target in targets) {
          String? createdDestination;
          try {
            final started = Stopwatch()..start();
            final reused = await store.findCompleteTarget(
              target.checksum,
              target.name,
            );
            final hadArchive = File(
              store.archivePath(target.checksum),
            ).existsSync();
            final result = await runPrepare(target);
            _traceBinaryOperation(
              target: target.name,
              operation: reused != null
                  ? 'reuse'
                  : hadArchive
                  ? 'extract'
                  : 'download',
              archiveBytes: _fileBytes(store.archivePath(target.checksum)),
              extractedBytes: _directoryBytes(result.entry.artifactPath),
              elapsedMilliseconds: started.elapsedMilliseconds,
              attempt: 0,
            );
            final artifact = result.entry.artifactPath;
            final relative = p.join(
              '.xa',
              target.checksum.toLowerCase().substring(0, 16),
              p.basename(artifact),
            );

            var aliased = false;
            if (packageLocalArtifactJunctionCapability) {
              final alias = p.join(manifestFile.parent.path, relative);

              await Directory(p.dirname(alias)).create(recursive: true);
              try {
                final existed =
                    FileSystemEntity.typeSync(alias, followLinks: false) !=
                    FileSystemEntityType.notFound;
                if (existed) {
                  if (!await preparer.validatesBinaryArtifactDestination(
                    source: artifact,
                    destination: alias,
                    alias: true,
                  )) {
                    throw FileSystemException(
                      'SwiftPM binary artifact alias already exists but is not managed for the expected artifact',
                      alias,
                    );
                  }
                } else {
                  await create(alias: alias, target: artifact);
                  createdDestination = alias;
                  createdDestinations[alias] = (
                    source: artifact,
                    publication: null,
                  );
                }
                localPaths[target] = relative;
                aliased = true;
              } on Object {
                if (createdDestination == alias) {
                  await remove(alias);
                  createdDestinations.remove(alias);
                  createdDestination = null;
                }
              }
            }
            if (!aliased) {
              final destination = p.join(manifestFile.parent.path, relative);
              final publication = await copy(
                source: artifact,
                destination: destination,
              );

              if (publication == SwiftPmBinaryArtifactPublication.published()) {
                createdDestination = destination;
                createdDestinations[destination] = (
                  source: artifact,
                  publication: publication,
                );
              }
              localPaths[target] = relative;
            }
          } on FlutterBuildError catch (error) {
            if (error.isSecurityFailure) rethrow;
            localPaths.remove(target);
            if (createdDestination != null) {
              final created = createdDestinations.remove(createdDestination)!;
              if (created.publication == null) {
                await remove(createdDestination);
              } else {
                await preparer.removeMaterializedBinaryArtifact(
                  source: created.source,
                  destination: createdDestination,
                  publication: created.publication!,
                );
              }
            }
          }
        }
        if (localPaths.isNotEmpty) {
          final rewritten = SwiftPmBinaryTargetManifest.rewriteToLocalPaths(
            original,
            localPaths,
          );
          await write(manifestFile.path, utf8.encode(rewritten));
        }
      } on Object {
        for (final created in createdDestinations.entries.toList().reversed) {
          if (created.value.publication == null) {
            await remove(created.key);
          } else {
            await preparer.removeMaterializedBinaryArtifact(
              source: created.value.source,
              destination: created.key,
              publication: created.value.publication!,
            );
          }
        }
        rethrow;
      }
    }
  }

  @visibleForTesting
  static Future<void> resolveWithFinalBinaryRecovery({
    required Future<void> Function() resolve,
    required Future<bool> Function() recover,
  }) async {
    try {
      await resolve();
    } on Object {
      if (!await recover()) rethrow;
      await resolve();
    }
  }

  @visibleForTesting
  static Future<SwiftPmBinaryArtifactPublication?> recoverFinalBinaryArtifact({
    required SwiftPmBinaryArtifactProvenance provenance,
    required String preparedArtifactPath,
    required String binaryArtifactStore,
    required String destination,
    required SwiftPmBinaryAttemptState attemptState,
    required bool packageLocalArtifactJunctionCapability,
    String? materializedDestination,
    CreateSwiftPmBinaryAlias? createAlias,
    MaterializeSwiftPmBinaryArtifact? materialize,
    StartBinaryCopy? materializeStartProcess,
    bool? windows,
  }) async {
    if (!(windows ?? Platform.isWindows)) return null;
    final key = binaryArtifactAttemptKey(provenance, windows: windows);
    if (attemptState.finalRecovered.contains(key)) return null;
    attemptState.finalRecovered.add(key);
    final preparer = SwiftPmBinaryArtifactPreparer(
      store: SwiftPmBinaryArtifactStore(binaryArtifactStore),
    );
    final create = createAlias ?? preparer.createBinaryArtifactJunction;
    final copy =
        materialize ??
        ({required source, required destination}) =>
            preparer.materializeBinaryArtifact(
              source: source,
              destination: destination,
              startProcess: materializeStartProcess,
            );
    if (packageLocalArtifactJunctionCapability) {
      try {
        final started = Stopwatch()..start();
        await create(alias: destination, target: preparedArtifactPath);
        _traceBinaryOperation(
          target: provenance.target.name,
          operation: 'recover',
          extractedBytes: _directoryBytes(preparedArtifactPath),
          elapsedMilliseconds: started.elapsedMilliseconds,
          attempt: 1,
        );
        return SwiftPmBinaryArtifactPublication.published();
      } on Object {
        if (attemptState.copied.contains(key)) return null;
      }
    }
    if (attemptState.copied.contains(key)) return null;
    attemptState.copied.add(key);
    final started = Stopwatch()..start();
    final publication = await copy(
      source: preparedArtifactPath,
      destination: materializedDestination ?? destination,
    );
    _traceBinaryOperation(
      target: provenance.target.name,
      operation: 'copy',
      extractedBytes: _directoryBytes(preparedArtifactPath),
      elapsedMilliseconds: started.elapsedMilliseconds,
      attempt: 1,
    );
    return publication;
  }

  @visibleForTesting
  static Future<bool> stageExtractedBinaryArtifacts({
    required String scratchPath,
    required String vendorDir,
    Map<String, String> packageIdentities = const {},
    String? binaryArtifactStore,
    String? binaryArtifactFallback,
    SwiftPmBinaryAttemptState? attemptState,
    bool packageLocalArtifactJunctionCapability = false,
    CreateSwiftPmBinaryAlias? createAlias,
    MaterializeSwiftPmBinaryArtifact? materialize,
    Future<void> Function(String destination)? removeDestination,
    Future<void> Function(String path, List<int> bytes)? writeManifest,
    bool? windows,
  }) async {
    if (!(windows ?? Platform.isWindows)) return false;
    if (binaryArtifactStore == null ||
        binaryArtifactFallback == null ||
        attemptState == null) {
      return false;
    }
    final artifactsRoot = p.join(scratchPath, 'artifacts');
    final artifacts = Directory(artifactsRoot);
    final vendor = Directory(vendorDir);
    final checkouts = Directory(p.join(scratchPath, 'checkouts'));
    if (!artifacts.existsSync() ||
        (!vendor.existsSync() && !checkouts.existsSync())) {
      return false;
    }
    final preparer = SwiftPmBinaryArtifactPreparer(
      store: SwiftPmBinaryArtifactStore(binaryArtifactStore),
    );
    var changed = false;
    final remove = removeDestination ?? _deleteEntity;
    final write = writeManifest ?? _writeAtomic;
    final packageRoots = <Directory>[
      if (vendor.existsSync()) vendor,
      if (checkouts.existsSync()) checkouts,
    ];
    for (final packageRoot in packageRoots) {
      await for (final package in packageRoot.list(followLinks: false)) {
        if (package is! Directory) continue;
        final packageIdentity =
            packageIdentities[p.normalize(package.path)] ??
            p.basename(package.path).toLowerCase();

        await for (final entity in package.list(followLinks: false)) {
          if (entity is! File) continue;
          final fileName = p.basename(entity.path);
          if (fileName != 'Package.swift' &&
              !(fileName.startsWith('Package@') &&
                  fileName.endsWith('.swift'))) {
            continue;
          }
          final originalBytes = await entity.readAsBytes();
          var manifest = utf8.decode(originalBytes);
          final createdDestinations =
              <
                String,
                ({String source, SwiftPmBinaryArtifactPublication publication})
              >{};
          final provenance = scanBinaryArtifactProvenance(
            packageIdentity: packageIdentity,
            manifestPath: entity.path,
            manifest: manifest,
          );
          for (final candidate in provenance.reversed) {
            final targetDirectory = Directory(
              p.join(artifactsRoot, packageIdentity, candidate.target.name),
            );
            if (!targetDirectory.existsSync()) continue;
            final archives = targetDirectory
                .listSync(followLinks: false)
                .whereType<File>()
                .where((file) => file.path.toLowerCase().endsWith('.zip'))
                .toList();
            final verified = <SwiftPmBinaryArtifactEntry>[];
            for (final archive in archives) {
              try {
                verified.add(
                  await preparer.prepareDownloadedArchive(
                    target: candidate.target,
                    archive: archive,
                  ),
                );
              } on FlutterBuildError catch (error) {
                if (error.isSecurityFailure) rethrow;
              }
            }
            if (verified.isEmpty) {
              final extracted = targetDirectory
                  .listSync(followLinks: false)
                  .whereType<Directory>()
                  .where(
                    (directory) =>
                        directory.path.toLowerCase().endsWith('.xcframework'),
                  )
                  .toList();
              if (extracted.length == 1) {
                final staging = await Directory(
                  binaryArtifactStore,
                ).createTemp('.extracted-');
                try {
                  final artifactName = p.basename(extracted.single.path);
                  await _copyResolvedArtifactTree(
                    extracted.single.path,
                    p.join(staging.path, artifactName),
                    includeTopLevel: (name) =>
                        name == 'Info.plist' || name == 'ios-arm64',
                  );

                  verified.add(
                    await SwiftPmBinaryArtifactStore(
                      binaryArtifactStore,
                    ).publishTarget(
                      checksum: candidate.target.checksum,
                      targetName: candidate.target.name,
                      stagingRoot: staging,
                      artifactDirectoryName: artifactName,
                      metadata: const {'source': 'swiftpm-extracted-artifact'},
                    ),
                  );
                } finally {
                  if (staging.existsSync()) {
                    await staging.delete(recursive: true);
                  }
                }
              }
            }
            if (verified.length != 1) continue;
            final relative = p.join(
              '.xa',
              candidate.target.checksum.toLowerCase().substring(0, 16),
              p.basename(verified.single.artifactPath),
            );

            final destination = p.join(package.path, relative);
            final fallbackDestination = destination;

            final existed =
                FileSystemEntity.typeSync(destination, followLinks: false) !=
                FileSystemEntityType.notFound;
            SwiftPmBinaryArtifactPublication? publication;
            if (existed && packageLocalArtifactJunctionCapability) {
              if (await preparer.validatesBinaryArtifactDestination(
                source: verified.single.artifactPath,
                destination: destination,
                alias: true,
              )) {
                publication = SwiftPmBinaryArtifactPublication.reused;
              }
            } else if (await preparer.validatesMaterializedBinaryArtifact(
              source: verified.single.artifactPath,
              destination: fallbackDestination,
            )) {
              publication = SwiftPmBinaryArtifactPublication.reused;
            } else {
              publication = await recoverFinalBinaryArtifact(
                provenance: candidate,
                preparedArtifactPath: verified.single.artifactPath,
                binaryArtifactStore: binaryArtifactStore,
                destination: destination,
                materializedDestination: fallbackDestination,
                attemptState: attemptState,
                packageLocalArtifactJunctionCapability:
                    packageLocalArtifactJunctionCapability,
                createAlias: createAlias,
                materialize: materialize,
                windows: windows,
              );
            }
            if (publication == null) continue;
            final usedAlias =
                packageLocalArtifactJunctionCapability &&
                await preparer.validatesBinaryArtifactDestination(
                  source: verified.single.artifactPath,
                  destination: destination,
                  alias: true,
                );
            final publishedDestination = usedAlias
                ? destination
                : fallbackDestination;
            if (publication == SwiftPmBinaryArtifactPublication.published()) {
              createdDestinations[publishedDestination] = (
                source: verified.single.artifactPath,
                publication: publication,
              );
            }
            manifest = SwiftPmBinaryTargetManifest.rewriteToLocalPaths(
              manifest,
              {candidate.target: relative},
            );

            changed = true;
          }
          if (!_sameBytes(originalBytes, utf8.encode(manifest))) {
            try {
              await _clearPlaceholderAttributes(entity.path);
              await write(entity.path, utf8.encode(manifest));
            } on Object {
              for (final created
                  in createdDestinations.entries.toList().reversed) {
                if (removeDestination != null) {
                  await remove(created.key);
                } else if (packageLocalArtifactJunctionCapability &&
                    p.isWithin(package.path, created.key)) {
                  await preparer.removeBinaryArtifactAlias(created.key);
                } else {
                  await preparer.removeMaterializedBinaryArtifact(
                    source: created.value.source,
                    destination: created.key,
                    publication: created.value.publication,
                  );
                }
              }
              rethrow;
            }
          }
        }
      }
    }
    return changed;
  }

  @visibleForTesting
  static Future<bool> normalizeResolvedPackageManifests(
    String scratchPath,
  ) async {
    final checkouts = Directory(p.join(scratchPath, 'checkouts'));
    var changed = false;
    if (checkouts.existsSync()) {
      for (final checkout in checkouts.listSync(followLinks: false)) {
        if (checkout is Directory) {
          changed =
              await _normalizeVendoredPackageManifests(
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
  @visibleForTesting
  static Future<void> buildWithInteropRecovery({
    required Future<void> Function() build,
    required Future<void> Function(String target) buildTarget,
    required String targetBuildDir,
    required Set<String> interopTargetCandidates,
    Future<void> Function()? repairConsumers,
    bool? windows,
  }) async {
    final repair = repairConsumers ?? () async {};

    Future<bool> recoverMissingTargets() async {
      final targets = missingSwiftInteropTargets(
        targetBuildDir,
        candidates: interopTargetCandidates,
      );
      for (final target in targets) {
        await buildTarget(target);
      }
      if (targets.isNotEmpty) await repair();
      return targets.isNotEmpty;
    }

    await repair();
    if (await recoverMissingTargets()) {
      await build();
      return;
    }

    final before = swiftInteropSearchPaths(targetBuildDir).toSet();
    try {
      await build();
    } on Object {
      if (await recoverMissingTargets()) {
        await build();
        return;
      }
      final emitted = swiftInteropSearchPaths(
        targetBuildDir,
      ).toSet().difference(before);
      if (!(windows ?? Platform.isWindows) || emitted.isEmpty) {
        rethrow;
      }
      await repair();
      await build();
    }
  }

  @visibleForTesting
  static List<String> missingSwiftInteropTargets(
    String targetBuildDir, {
    required Set<String> candidates,
  }) {
    final directory = Directory(targetBuildDir);
    if (!directory.existsSync()) return const [];
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
        if (candidates.contains(target)) targets.add(target);
      }
    }
    final sorted = targets.toList()..sort();
    return sorted;
  }

  @visibleForTesting
  static Set<String> dependencyProductNames(String manifest) => {
    for (final call in _swiftCalls(manifest, '.product'))
      if (_namedString(call.text, 'name') case final String name) name,
  };

  @visibleForTesting
  static Future<void> repairSwiftInteropConsumers({
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
        if (source != original) await _writeStable(entity.path, source);
      }
    }
  }

  /// Process-local settings for Windows SwiftPM dependency checkout and
  /// sentry-cocoa's source-build manifest lane.
  static Map<String, String>? swiftProcessEnvironment({bool? windows}) {
    if (!(windows ?? Platform.isWindows)) return null;
    return {
      'GIT_CONFIG_COUNT': '1',
      'GIT_CONFIG_KEY_0': 'core.symlinks',
      'GIT_CONFIG_VALUE_0': 'false',
      'EXPERIMENTAL_SPM_BUILDS': '1',
    };
  }

  /// Resolves Windows dependencies before tracked symlink placeholders are
  /// materialized and automatic resolution is disabled for the build.
  static List<String> swiftResolveArguments({
    required String pluginsDir,
    required String scratchPath,
    required String swiftSdksPath,
    required String toolsetPath,
  }) => [
    'package',
    '--package-path',
    pluginsDir,
    '--scratch-path',
    scratchPath,
    '--swift-sdks-path',
    swiftSdksPath,
    '--swift-sdk',
    'arm64-apple-ios',
    '--toolset',
    toolsetPath,
    'resolve',
  ];

  /// Compiles and caches the Swift compiler plugin stub that answers
  /// `#Preview` macro-expansion requests with empty source, so builds
  /// succeed without Apple's `PreviewsMacros` plugin (an Xcode-only,
  /// closed-source binary with no host build of its own).
  ///
  /// `#Preview` is a freestanding declaration macro (SE-0394's SwiftUI
  /// sibling proposal), so expanding it to nothing is a legal expansion
  /// wherever it appears: previews are development-only UI and
  /// contribute nothing to the app being built. The stub speaks
  /// swift-syntax's own `StandardIOMessageConnection` wire protocol
  /// directly (an 8-byte little-endian length prefix, then UTF-8 JSON;
  /// see swift-syntax/Sources/SwiftCompilerPluginMessageHandling), so it
  /// has no swift-syntax dependency of its own, only C standard I/O.
  /// This is a real implementation of `swift build`'s public
  /// `-load-plugin-executable` extension point, not a source patch: no
  /// plugin source is read or modified.
  ///
  /// Its C source lives at `assets/preview_macro_stub.c` and is embedded
  /// as [previewMacroStubSource] — see that constant's doc comment.
  @visibleForTesting
  static Future<String> writePreviewMacroStub({
    required String outputDir,
    required String cCompilerPath,
    bool? windows,
  }) async {
    final onWindows = windows ?? Platform.isWindows;
    final stubDir = p.join(outputDir, '.xcross', 'preview-macro-stub');
    await Directory(stubDir).create(recursive: true);
    final sourcePath = p.join(stubDir, 'stub.c');
    await _writeStable(sourcePath, previewMacroStubSource);
    final exePath = p.join(
      stubDir,
      ProcessRunner.hostExecutableName('stub', windows: onWindows),
    );
    // The stub only depends on its own source, so a matching binary from
    // a previous build needs no recompilation.
    if (File(exePath).existsSync()) return exePath;
    await ProcessRunner.runChecked(cCompilerPath, [
      '-O2',
      '-o',
      exePath,
      sourcePath,
    ], label: 'compile preview macro stub');
    return exePath;
  }

  @visibleForTesting
  static Future<String> writeObjectiveCCompatibilityHeader(
    String outputDir,
  ) async {
    final path = p.join(outputDir, '.xcross', 'objective-c-compatibility.h');
    await Directory(p.dirname(path)).create(recursive: true);
    await _writeStable(
      path,
      '#ifdef __OBJC__\n#import <Foundation/Foundation.h>\n#endif\n',
    );
    return path;
  }

  /// Search-path arguments for the Objective-C interop modules SwiftPM
  /// generates under [targetBuildDir].
  ///
  /// A package whose Objective-C headers forward-declare types its Swift
  /// half implements leaves those declarations incomplete for anything that
  /// reads the headers alone, which drops every member mentioning them.
  /// Swift emits the completing declarations into `<Module>.build/include`,
  /// and SwiftPM puts that directory on the search path of the targets it
  /// knows consume the Swift module. A target reaching the same headers
  /// through a generated compatibility module is not one of them, so Clang
  /// never sees the completing declarations. Passing the directories to
  /// Clang covers those targets as well.
  ///
  /// SwiftPM writes each directory before compiling the targets that depend
  /// on it, so on a clean build this starts empty and fills in as the
  /// dependencies are built.
  @visibleForTesting
  static List<String> swiftInteropSearchPaths(String targetBuildDir) {
    final directory = Directory(targetBuildDir);
    if (!directory.existsSync()) return const [];
    final includes = <String>[];
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.build')) continue;
      final include = p.join(entity.path, 'include');
      final module = name.substring(0, name.length - '.build'.length);
      if (File(p.join(include, '$module-Swift.h')).existsSync()) {
        includes.add(include);
      }
    }
    includes.sort();
    return [
      for (final include in includes) ...['-Xcc', '-I', '-Xcc', include],
    ];
  }

  /// Disables Clang's implicit-module lock files, whose POSIX lock
  /// protocol deadlocks competing frontends on Windows.
  ///
  /// Applied to the C/Objective-C targets and to Swift's own frontend,
  /// which builds implicit Clang modules through the same cache.
  @visibleForTesting
  static const List<String> noImplicitModuleLockArguments = [
    '-Xcc',
    '-Xclang',
    '-Xcc',
    '-fno-implicit-modules-use-lock',
    '-Xswiftc',
    '-Xcc',
    '-Xswiftc',
    '-Xclang',
    '-Xswiftc',
    '-Xcc',
    '-Xswiftc',
    '-fno-implicit-modules-use-lock',
  ];

  /// Arguments shared by Linux and Windows SwiftPM builds. SDK-owned compiler
  /// flags stay in SDK metadata; only package-specific flags belong here.
  static List<String> swiftBuildArguments({
    required String pluginsDir,
    required String scratchPath,
    required String swiftSdksPath,
    required String iosSdk,
    required String flutterFrameworkSlice,
    String? objectiveCCompatibilityHeader,
    String? toolsetPath,
    String? linkerPath,
    bool? windows,
    List<String> interopSearchPaths = const [],
    String? previewMacroStubPath,
  }) => [
    'build',
    '--package-path',
    pluginsDir,
    '--configuration',
    'debug',
    // A debug build with DWARF makes swift-driver plan a dSYM job for Darwin
    // targets, and that job needs a `dsymutil` no cross host is guaranteed to
    // have ("error: unableToFind(tool: \"dsymutil\")" on Linux). Nothing here
    // consumes a dSYM — only the dylibs are collected — and the Runner is
    // compiled without debug info too, so drop it instead of adding a tool
    // requirement.
    '-debug-info-format',
    'none',
    '--swift-sdks-path',
    swiftSdksPath,
    '--swift-sdk',
    'arm64-apple-ios',
    if (toolsetPath != null) ...['--toolset', toolsetPath],
    '--scratch-path',
    scratchPath,
    if (windows ?? Platform.isWindows) ...[
      '--disable-automatic-resolution',
      // Windows Swift's interface verifier does not inherit SwiftPM's search
      // path for generated sibling Clang modules during Darwin cross builds.
      // The binary module is still emitted and used by this debug build.
      '-Xswiftc',
      '-no-verify-emitted-module-interface',
      // Clang guards implicit module builds with filesystem lock files so
      // competing invocations reuse one another's work instead of building
      // the same module twice. That protocol assumes POSIX lock semantics
      // and deadlocks on Windows: the frontend holding a module's lock
      // stops progressing and every other frontend waits on it forever, so
      // the build hangs with no diagnostic and no CPU use. Each build owns
      // its module cache, so dropping the lock only risks building a module
      // twice in parallel, which is far cheaper than hanging. Swift builds
      // implicit Clang modules through its own frontend, so it needs the
      // flag as well as the C/Objective-C targets.
      ...noImplicitModuleLockArguments,
    ],
    ...interopSearchPaths,
    // Apple's `PreviewsMacros` plugin ships only inside Xcode, so `#Preview`
    // needs the stub on every cross host, not just Windows.
    if (previewMacroStubPath != null) ...[
      '-Xswiftc',
      '-load-plugin-executable',
      '-Xswiftc',
      '$previewMacroStubPath#PreviewsMacros',
    ],
    // On macOS, SwiftPM's host toolchain can override the Swift SDK bundle's
    // sdkRootPath with the host MacOSX SDK. Pin the installed iPhoneOS SDK for
    // Swift imports and every C/Objective-C target so UIKit and Foundation are
    // resolved from the target platform on every host.
    '-Xswiftc',
    '-sdk',
    '-Xswiftc',
    iosSdk,
    '-Xcc',
    '-isysroot',
    '-Xcc',
    iosSdk,
    if (objectiveCCompatibilityHeader != null) ...[
      '-Xcc',
      '-include',
      '-Xcc',
      objectiveCCompatibilityHeader,
    ],
    '-Xswiftc',
    '-F',
    '-Xswiftc',
    flutterFrameworkSlice,
    '-Xcc',
    '-F',
    '-Xcc',
    flutterFrameworkSlice,
    '-Xswiftc',
    '-Xfrontend',
    '-Xswiftc',
    '-disable-availability-checking',
    // Swift uses clang as its link driver. Pin that driver too, otherwise a
    // macOS host reselects MacOSX.sdk while linking iOS plugin products.
    '-Xswiftc',
    '-Xclang-linker',
    '-Xswiftc',
    '-isysroot',
    '-Xswiftc',
    '-Xclang-linker',
    '-Xswiftc',
    iosSdk,
    ...objectiveCLinkerSwiftDriverArguments,
    if (!(windows ?? Platform.isWindows))
      ...objectiveCSmallStubSwiftDriverArguments,
    // The link runs through the toolchain's own clang, which resolves
    // `-use-ld=lld` to the `ld64.lld` sitting next to itself — swiftly's, the
    // one that refuses iOS (see [resolveLd64Lld]). `--ld-path` overrides that
    // choice with the stock LLVM linker.
    if (linkerPath != null) ...[
      '-Xswiftc',
      '-Xclang-linker',
      '-Xswiftc',
      '--ld-path=$linkerPath',
    ],
  ];

  /// Finds and fixes every dylib emitted into SwiftPM's target debug output.
  @visibleForTesting
  static Future<GeneratedPluginsBuildResult> discoverAndRewriteDylibs(
    String targetDebugDir,
  ) async {
    final dylibPaths = <String>[];
    await for (final entity in Directory(targetDebugDir).list()) {
      if (entity is File && p.extension(entity.path) == '.dylib') {
        dylibPaths.add(p.absolute(entity.path));
      }
    }
    dylibPaths.sort();

    const aggregateName = 'lib$_pluginsProductName.dylib';
    final aggregatePath = dylibPaths
        .where((path) => p.basename(path) == aggregateName)
        .firstOrNull;
    if (aggregatePath == null) {
      throw FlutterBuildError(
        'GeneratedPluginsPackage: swift build did not produce the plugins '
        'library in $targetDebugDir',
      );
    }

    final dylibNames = dylibPaths.map(p.basename).toSet();
    for (final path in dylibPaths) {
      await MachODylibRewriter.rewriteFile(
        path,
        producedDylibNames: dylibNames,
        repairObjCFastStubs: Platform.isLinux,
      );
    }
    // SwiftPM emits .swiftmodule files into a sibling `Modules` directory;
    // app-extension targets importing a plugin need it on their include path.
    final modules = Directory(p.join(targetDebugDir, 'Modules'));
    return GeneratedPluginsBuildResult(
      libraryPath: aggregatePath,
      dylibPaths: List.unmodifiable(dylibPaths),
      modulesDir: modules.existsSync() ? p.absolute(modules.path) : null,
    );
  }

  static Future<Map<String, Object>> resolveBuildToolchainIdentity(
    DarwinSdk sdk,
  ) async => SdkInstall.swiftPmBuildToolchainIdentity(
    cCompilerPath: await DarwinSdk.resolveDarwinClang(sdk),
    cxxCompilerPath: await DarwinSdk.resolveDarwinClang(sdk, name: 'clang++'),
    linkerPath: await DarwinSdk.resolveLd64Lld(sdk),
    librarianPath: await resolveLibrarian(),
  );

  /// LLVM's drop-in replacement for Apple's `libtool`.
  static const _libtool = 'llvm-libtool-darwin';

  /// Every archiver SwiftPM may be pointed at, best first.
  static const _librarians = [_libtool, 'llvm-ar'];

  /// Writes SwiftPM's external toolset and returns its path.
  ///
  /// Every host needs the `librarian` entry: SwiftPM validates the toolchain
  /// against the *target* triple before building, and for an Apple triple that
  /// means Apple's `libtool` ("toolchain is invalid: could not find CLI tool
  /// `libtool`"), which no cross host has. Windows overrides the compilers and
  /// the linker on top; Linux passes its linker as a `swift build` flag
  /// instead.
  static Future<String> writeToolset({
    required String outputDir,
    required String linkerPath,
    String? cCompilerPath,
    String? cxxCompilerPath,
    bool? windows,
    Future<String?> Function(String name)? locateTool,
    String? librarianPath,
  }) async {
    final onWindows = windows ?? Platform.isWindows;
    final output = Directory(outputDir);
    await output.create(recursive: true);
    // LLVM often never registers itself on PATH, so reach into its install
    // directories too (see [DarwinSdk.llvmToolDirs]).
    final locate = locateTool ?? DarwinSdk.locateLlvmTool;
    final toolset = <String, Object>{
      'schemaVersion': '1.0',
      'rootPath': _jsonPath(output.resolveSymbolicLinksSync()),
    };

    Future<String?> resolve(String name) async {
      final path = await locate(
        ProcessRunner.hostExecutableName(name, windows: onWindows),
      );
      return path == null
          ? null
          : _jsonPath(File(path).resolveSymbolicLinksSync());
    }

    final librarian =
        librarianPath ??
        await resolveLibrarian(windows: onWindows, locateTool: locateTool);
    toolset['librarian'] = {'path': librarian};

    if (onWindows) {
      // Vetted by DarwinSdk.resolveDarwinClang where the caller could do it;
      // a plain lookup is the fallback for tests and older call sites.
      final tools = <String, (String, String?)>{
        'cCompiler': ('clang', cCompilerPath),
        'cxxCompiler': ('clang++', cxxCompilerPath),
      };
      for (final tool in tools.entries) {
        final vetted = tool.value.$2;
        final path = vetted == null
            ? await resolve(tool.value.$1)
            : _jsonPath(File(vetted).resolveSymbolicLinksSync());
        if (path == null) {
          throw FlutterBuildError('Could not find ${tool.value.$1}.');
        }
        toolset[tool.key] = {
          'path': path,
          'extraCLIOptions': [r'-fdebug-prefix-map=C:\=/'],
        };
      }
      // The Swift toolchain's own ld64.lld refuses iOS, so take the linker
      // already vetted by DarwinSdk.resolveLd64Lld instead of PATH order.
      toolset['linker'] = {
        'path': _jsonPath(File(linkerPath).resolveSymbolicLinksSync()),
      };
    }

    final toolsetPath = p.join(outputDir, 'xcross-toolset.json');
    await _writeStable(
      toolsetPath,
      '${const JsonEncoder.withIndent('  ').convert(toolset)}\n',
    );
    return toolsetPath;
  }

  /// Picks the archiver for an Apple target: `llvm-libtool-darwin` when it is
  /// on PATH, else the copy sitting next to `llvm-ar` inside LLVM's own bin
  /// directory (Debian and Ubuntu only symlink a subset of LLVM into
  /// `/usr/bin`), else `llvm-ar` itself.
  @visibleForTesting
  static Future<String> resolveLibrarian({
    bool? windows,
    Future<String?> Function(String name)? locateTool,
  }) async {
    final onWindows = windows ?? Platform.isWindows;
    final locate = locateTool ?? DarwinSdk.locateLlvmTool;
    Future<String?> resolve(String name) async {
      final path = await locate(
        ProcessRunner.hostExecutableName(name, windows: onWindows),
      );
      return path == null
          ? null
          : _jsonPath(File(path).resolveSymbolicLinksSync());
    }

    final librarian = await _resolveLibrarian(onWindows, resolve);
    if (librarian != null) return librarian;
    throw FlutterBuildError(
      'No Darwin-capable archiver found (${_librarians.join(' or ')}). '
      'Install LLVM and retry.',
    );
  }

  static Future<String?> _resolveLibrarian(
    bool windows,
    Future<String?> Function(String name) resolve,
  ) async {
    final libtool = await resolve(_libtool);
    if (libtool != null) return libtool;
    final archiver = await resolve('llvm-ar');
    if (archiver == null) return null;
    final sibling = p.join(
      p.dirname(archiver),
      ProcessRunner.hostExecutableName(_libtool, windows: windows),
    );
    return File(sibling).existsSync() ? _jsonPath(sibling) : archiver;
  }

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
  @visibleForTesting
  static Future<void> writeGeneratedPackages({
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
    final windows = Platform.isWindows;
    final packagesDir = p.join(outputDir, 'Packages');
    final frameworkDir = p.join(packagesDir, _flutterFrameworkPackageName);
    final pluginsDir = p.join(outputDir, 'Plugins');
    final resolvedVendorDir = vendorDir ?? p.join(outputDir, 'vendor');
    final shouldVendor = vendorRemotePackages ?? true;

    await Directory(packagesDir).create(recursive: true);
    await _writeFlutterFrameworkPackage(
      frameworkDir: frameworkDir,
      flutterXcframework: flutterXcframework,
      copyFlutterXcframework: copyFlutterXcframework ?? windows,
    );

    final pluginTargets = {
      for (final plugin in plugins) plugin.name: plugin.swiftPackageDir,
    };
    final pluginPackageDirs = <String, String>{};
    final vendorNormalizationCache = <String, Map<String, List<String>>>{};
    final dependencyEvaluationCache = <String, Future<Map<String, String>>>{};
    final vendorCheckoutCache = <String, Future<void>>{};

    for (final plugin in plugins) {
      final packageAlias = p.join(packagesDir, plugin.name);
      pluginPackageDirs[plugin.name] = await _stagePluginPackage(
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
        evaluateDependencyRefs: evaluateDependencyRefs,
        clonePackage: clonePackage,
      );
    }
    if (windows &&
        shouldVendor &&
        binaryArtifactStore != null &&
        binaryArtifactFallback != null) {
      await prepareSupportedBinaryArtifacts(
        packageRoot: resolvedVendorDir,
        binaryArtifactStore: binaryArtifactStore,
        binaryArtifactFallback: binaryArtifactFallback,
        packageLocalArtifactJunctionCapability:
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
      for (final call in _swiftCalls(manifest, '.package').reversed) {
        final dependencyPath = _namedString(call.text, 'path');
        if (dependencyPath == null) continue;
        final dependencyName =
            _namedString(call.text, 'name') ?? p.basename(dependencyPath);
        final sharedPackage = packagesByDirectoryName[dependencyName];
        if (sharedPackage == null || p.equals(dependencyPath, sharedPackage)) {
          continue;
        }
        final rewritten = call.text.replaceFirst(
          RegExp(r'path\s*:\s*"[^"]+"'),
          'path: "${_swiftPath(sharedPackage)}"',
        );
        manifest = manifest.replaceRange(call.start, call.end, rewritten);
      }
      if (manifest != original) await _writeStable(manifestFile.path, manifest);
    }
    await _writePluginsPackage(
      pluginsDir: pluginsDir,
      frameworkDir: frameworkDir,
      plugins: plugins,
      pluginPackageDirs: pluginPackageDirs,
      deploymentTarget: deploymentTarget,
      verbose: verbose,
    );
  }

  /// Stages [target] at [alias], using a shallow overlay when the Swift
  /// manifest needs host fixes (linker flags, Windows CRT imports) or when
  /// remote URL dependencies are vendored to path deps.
  ///
  /// [platformDir] is the package-root subdirectory [target] sits in — `ios`
  /// normally, `darwin` for shared-source Apple plugins. The staged tree keeps
  /// the same shape so relative paths inside the plugin's `Package.swift`
  /// (`../../src`, shared header search paths) still resolve.
  static Future<String> _stagePluginPackage({
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
      await _deleteUnless(alias, FileSystemEntityType.directory);
      final packageRoot = p.dirname(p.dirname(target));
      await _stageAncestorOverlay(
        sourceRoot: packageRoot,
        destinationRoot: alias,
        packageName: p.basename(target),
        platformDir: platformDir,
      );
      await _createDirectoryAlias(
        p.join(alias, platformDir, _flutterFrameworkPackageName),
        p.join(p.dirname(alias), _flutterFrameworkPackageName),
      );
      stagedPackage = p.join(alias, platformDir, p.basename(target));
    }

    final manifest = await File(p.join(target, 'Package.swift')).readAsString();
    var normalizedManifest = removeMissingResources(
      normalizeHostManifest(manifest),
      target,
    );
    for (final call in _swiftCalls(normalizedManifest, '.package').reversed) {
      final relativePath = _namedString(call.text, 'path');
      if (relativePath == null || p.isAbsolute(relativePath)) continue;
      final dependencyName =
          _namedString(call.text, 'name') ?? p.basename(relativePath);
      final targetPath = packageTargets[dependencyName];
      if (targetPath == null) continue;
      final rewritten = call.text.replaceFirst(
        RegExp(r'path\s*:\s*"[^"]+"'),
        'path: "${_swiftPath(targetPath)}"',
      );
      normalizedManifest = normalizedManifest.replaceRange(
        call.start,
        call.end,
        rewritten,
      );
    }
    final fallbackSwiftModules = <String, List<String>>{};
    if (vendorDir != null) {
      await _mirrorPluginPackage(target, stagedPackage, normalizedManifest);
      normalizedManifest = await vendorUrlPackagesAsPathDeps(
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
        swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
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
      await _mirrorPluginPackage(
        target,
        stagedPackage,
        normalizedManifest,
        transform: _hostSwiftTransform(fallbackSwiftModules),
      );
    } else if (normalizedManifest == manifest) {
      await _createDirectoryAlias(stagedPackage, target);
      await normalizeHostSwiftTree(
        stagedPackage,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    } else {
      await _overlayPluginManifest(target, stagedPackage, normalizedManifest);
      await normalizeHostSwiftTree(
        stagedPackage,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    }
    if (Platform.isWindows &&
        binaryArtifactStore != null &&
        binaryArtifactFallback != null) {
      await prepareSupportedBinaryArtifacts(
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
  static Future<void> _mirrorPluginPackage(
    String target,
    String staged,
    String manifest, {
    _SourceTransform? transform,
  }) async {
    await _deleteUnless(staged, FileSystemEntityType.directory);
    await _syncDirectory(
      target,
      staged,
      preserve: const {'Package.swift'},
      transform: transform,
    );
    await _writeStable(p.join(staged, 'Package.swift'), manifest);
  }

  /// The host-compatibility source rewrite as a sync transform, electing
  /// Swift sources but never package manifests or binary files.
  static _SourceTransform _hostSwiftTransform(
    Map<String, List<String>> fallbackSwiftModules,
  ) => (path) {
    final name = p.basename(path);
    final isManifest =
        name == 'Package.swift' ||
        (name.startsWith('Package@') && name.endsWith('.swift'));
    if (p.extension(name) != '.swift' || isManifest) return null;
    return (content) => normalizeHostSwiftSource(
      content,
      fallbackSwiftModules: fallbackSwiftModules,
    );
  };

  /// Stages [target] at [staged] as per-entry aliases beneath a rewritten
  /// `Package.swift`, for hosts where symbolic links are first-class.
  static Future<void> _overlayPluginManifest(
    String target,
    String staged,
    String manifest,
  ) async {
    await _deleteEntity(staged);
    await Directory(staged).create(recursive: true);
    await _writeStable(p.join(staged, 'Package.swift'), manifest);
    await for (final entity in Directory(target).list(followLinks: false)) {
      if (p.basename(entity.path) == 'Package.swift') continue;
      await _stageEntity(
        entity,
        p.join(staged, p.basename(entity.path)),
        copyDirectories: false,
      );
    }
  }

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

  static Future<void> _stageAncestorOverlay({
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
      await _stageEntity(
        entity,
        p.join(destinationRoot, name),
        copyDirectories: true,
        excludedSourcePath: destinationRoot,
      );
    }
    await _pruneUnexpected(destinationRoot, staged);

    final stagedIos = <String>{packageName, _flutterFrameworkPackageName};
    await for (final entity in Directory(
      p.join(sourceRoot, platformDir),
    ).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == packageName || name == _flutterFrameworkPackageName) continue;
      stagedIos.add(name);
      await _stageEntity(
        entity,
        p.join(destinationRoot, platformDir, name),
        copyDirectories: true,
        excludedSourcePath: destinationRoot,
      );
    }
    await _pruneUnexpected(p.join(destinationRoot, platformDir), stagedIos);
  }

  /// Deletes entries of [directory] not named in [expected], so previously
  /// staged files that no longer qualify do not linger in the build tree.
  static Future<void> _pruneUnexpected(
    String directory,
    Set<String> expected,
  ) async {
    await for (final entity in Directory(directory).list(followLinks: false)) {
      if (!expected.contains(p.basename(entity.path))) {
        await _deleteEntity(entity.path);
      }
    }
  }

  static Future<void> _stageEntity(
    FileSystemEntity entity,
    String destination, {
    required bool copyDirectories,
    String? excludedSourcePath,
  }) async {
    final resolved = entity is Link
        ? entity.resolveSymbolicLinksSync()
        : entity.path;
    if (!Directory(resolved).existsSync()) {
      await _syncFile(File(resolved), destination);
    } else if (copyDirectories) {
      await _syncDirectory(
        resolved,
        destination,
        excludedSourcePath: excludedSourcePath,
      );
    } else {
      await _createDirectoryAlias(destination, resolved);
    }
  }

  /// Writes `FlutterFramework/Package.swift` and links or copies the real
  /// [flutterXcframework]. Windows copies because creating symlinks commonly
  /// requires Developer Mode or elevation.
  static Future<void> _writeFlutterFrameworkPackage({
    required String frameworkDir,
    required String flutterXcframework,
    required bool copyFlutterXcframework,
  }) async {
    await Directory(frameworkDir).create(recursive: true);
    await _writeStable(
      p.join(frameworkDir, 'Package.swift'),
      flutterFrameworkManifest(),
    );

    final frameworkPath = p.join(frameworkDir, 'Flutter.xcframework');
    if (copyFlutterXcframework) {
      await _deleteUnless(frameworkPath, FileSystemEntityType.directory);
      await _syncDirectory(flutterXcframework, frameworkPath);
    } else {
      await _deleteEntity(frameworkPath);
      await Link(frameworkPath).create(flutterXcframework);
    }
  }

  /// Writes `Plugins/Package.swift` and the generated registrant source.
  static Future<void> _writePluginsPackage({
    required String pluginsDir,
    required String frameworkDir,
    required List<IosPlugin> plugins,
    required Map<String, String> pluginPackageDirs,
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
  }) async {
    final sourcesDir = p.join(pluginsDir, 'Sources', _pluginsProductName);
    await Directory(sourcesDir).create(recursive: true);

    await _writeStable(
      p.join(pluginsDir, 'Package.swift'),
      pluginsManifest(
        plugins,
        frameworkDir,
        pluginPackageDirs: pluginPackageDirs,
        deploymentTarget: deploymentTarget,
      ),
    );

    await _writeStable(
      p.join(sourcesDir, 'GeneratedPluginRegistrant.swift'),
      registrantSource(plugins, verbose: verbose),
    );
  }

  /// `FlutterFramework/Package.swift` contents — wraps `Flutter.xcframework`
  /// as a SwiftPM binary target.
  @visibleForTesting
  static String flutterFrameworkManifest() =>
      '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$_flutterFrameworkPackageName",
    products: [
        .library(name: "$_flutterFrameworkPackageName", targets: ["$_flutterFrameworkPackageName"])
    ],
    targets: [
        .binaryTarget(name: "$_flutterFrameworkPackageName", path: "Flutter.xcframework")
    ]
)
''';

  /// Rewrites Clang-style `-Wl,<argument>...` manifest tokens into the
  /// equivalent arguments accepted by the Swift compiler driver.
  @visibleForTesting
  static String normalizeLinkerFlags(String manifest) =>
      manifest.replaceAllMapped(RegExp(r'"-Wl,([^"\\]+)"'), (match) {
        final arguments = match.group(1)!.split(',');
        if (arguments.any((argument) => argument.isEmpty)) {
          return match.group(0)!;
        }
        return [
          for (final argument in arguments) ...['"-Xlinker"', '"$argument"'],
        ].join(', ');
      });

  @visibleForTesting
  static String removeMissingResources(String manifest, String packageDir) {
    final targets = _swiftCalls(manifest, '.target');
    final resourcePattern = RegExp(
      r'\.((?:process|copy))\(\s*"([^"]+)"\s*\)\s*,?',
    );
    var result = manifest;
    for (final match
        in resourcePattern.allMatches(manifest).toList().reversed) {
      var root = packageDir;
      for (final target in targets) {
        if (target.start > match.start || target.end < match.end) continue;
        final explicitPath = _namedString(target.text, 'path');
        final name = _namedString(target.text, 'name');
        if (explicitPath != null) {
          root = p.joinAll([packageDir, ...explicitPath.split('/')]);
        } else if (name != null) {
          root = p.join(packageDir, 'Sources', name);
        }
        break;
      }
      final resource = p.joinAll([root, ...match.group(2)!.split('/')]);
      if (FileSystemEntity.typeSync(resource) ==
          FileSystemEntityType.notFound) {
        result = result.replaceRange(match.start, match.end, '');
      }
    }
    return result;
  }

  /// Host-side Package.swift fixes for cross builds.
  ///
  /// Includes [normalizeLinkerFlags], plus Windows Swift 6+ CRT imports so
  /// manifests that call `getenv` via removed `MSVCRT` (notably sentry-cocoa)
  /// still compile on the host, and drops the Foundation-only
  /// `String(cString:encoding:)` overload that manifests cannot use.
  @visibleForTesting
  static String normalizeHostManifest(String manifest) {
    var result = normalizeLinkerFlags(manifest);
    // sentry-cocoa and similar: Darwin/Glibc/MSVCRT — MSVCRT was replaced by
    // CRT on Windows Swift 6 (https://github.com/apple/swift/pull/34299).
    final beforeCrtNormalization = result;
    result = result.replaceAllMapped(
      RegExp(r'#elseif\s+canImport\(MSVCRT\)\r?\nimport MSVCRT'),
      (match) {
        final prefix = beforeCrtNormalization.substring(0, match.start);
        if (prefix.endsWith(
          '#elseif canImport(CRT)\n'
          'import CRT\n'
          '#elseif canImport(ucrt)\n'
          'import ucrt\n',
        )) {
          return match.group(0)!;
        }
        return '#elseif canImport(CRT)\n'
            'import CRT\n'
            '#elseif canImport(ucrt)\n'
            'import ucrt\n'
            '#elseif canImport(MSVCRT)\n'
            'import MSVCRT';
      },
    );
    result = exposeMacOSPackageGraphEntries(result);
    result = result.replaceAllMapped(
      RegExp(r'(path:\s*"FirebaseSessions/Sources",)(\s*)(cSettings:)'),
      (match) => '${match[1]}${match[2]}sources: ["."],${match[2]}${match[3]}',
    );
    result = result.replaceAllMapped(
      RegExp(r'(name:\s*"GoogleDataTransport",)(\s*)(platforms:)'),
      (match) =>
          '${match[1]}${match[2]}defaultLocalization: "en",${match[2]}${match[3]}',
    );
    result = result.replaceAllMapped(
      RegExp(r'"([^"\r\n]+)/"'),
      (match) => '"${match[1]}"',
    );
    // Package manifests cannot import Foundation; stdlib String(cString:)
    // already decodes UTF-8 (getsentry/sentry-cocoa#7797).
    result = result.replaceAllMapped(
      RegExp(r'String\(cString:\s*([^,]+),\s*encoding:\s*\.utf8\)'),
      (match) => 'String(cString: ${match[1]})',
    );
    final sourceProduct = RegExp(
      r'products\.append\(\s*\.library\([\s\S]*?\)\s*\)',
    ).firstMatch(result);
    if (result.contains('EXPERIMENTAL_SPM_BUILDS') &&
        sourceProduct != null &&
        !result.contains('products.removeAll()')) {
      final blockStart = result.lastIndexOf('{', sourceProduct.start);
      if (blockStart >= 0) {
        result = result.replaceRange(
          blockStart + 1,
          blockStart + 1,
          '\n    products.removeAll()\n    targets.removeAll()',
        );
      }
    }
    return result;
  }

  /// Injects `import <fallback>` lines ahead of imports of a package whose
  /// Windows build fell back to source and needs its Swift half imported
  /// alongside its Objective-C compatibility module (see
  /// [synthesizeBinaryFallbackCompatibility]).
  ///
  /// `#Preview` no longer needs handling here: [writePreviewMacroStub]
  /// answers the macro through Swift's own plugin protocol, so preview
  /// declarations compile unmodified instead of being blanked out.
  @visibleForTesting
  static String normalizeHostSwiftSource(
    String source, {
    Map<String, List<String>> fallbackSwiftModules = const {},
  }) {
    if (fallbackSwiftModules.isEmpty) return source;

    final importPattern = RegExp(
      r'^([ \t]*(?:(?:@[A-Za-z_][\w.]*(?:\([^\r\n]*\))?[ \t]+)*)'
      r'import[ \t]+)([A-Za-z_][A-Za-z0-9_]*)([ \t]*)(\r?\n|$)',
      multiLine: true,
    );
    final importCode = _swiftCodeMask(source);
    final seen = <String>{};
    for (final match in importPattern.allMatches(source)) {
      final importOffset = match.start + match[1]!.lastIndexOf('import');
      if (importCode[importOffset]) {
        seen.add('${match[1]}${match[2]}');
      }
    }
    return source.replaceAllMapped(importPattern, (match) {
      final importOffset = match.start + match[1]!.lastIndexOf('import');
      if (!importCode[importOffset]) {
        return match[0]!;
      }
      final modules = fallbackSwiftModules[match[2]];
      if (modules == null) return match[0]!;
      final imports = [
        for (final module in modules)
          if (seen.add('${match[1]}$module')) '${match[1]}$module',
      ];
      if (imports.isEmpty) return match[0]!;
      final newline = match[4]!.isEmpty ? '\n' : match[4]!;
      return '${imports.join(newline)}$newline${match[0]}';
    });
  }

  /// Normalizes regular Swift source files below [root] without following
  /// links. Every source is analyzed before any file is changed.
  @visibleForTesting
  static Future<void> normalizeHostSwiftTree(
    String root, {
    Map<String, List<String>> fallbackSwiftModules = const {},
  }) async {
    if (FileSystemEntity.typeSync(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final files = <File>[];

    Future<void> collect(String directory) async {
      await for (final entity in Directory(
        directory,
      ).list(followLinks: false)) {
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await collect(entity.path);
        } else if (type == FileSystemEntityType.file &&
            p.extension(entity.path) == '.swift') {
          final name = p.basename(entity.path);
          if (name != 'Package.swift' &&
              !(name.startsWith('Package@') && name.endsWith('.swift'))) {
            files.add(File(entity.path));
          }
        }
      }
    }

    await collect(root);
    final changes = <File, String>{};
    for (final file in files) {
      final original = await file.readAsString();
      final normalized = normalizeHostSwiftSource(
        original,
        fallbackSwiftModules: fallbackSwiftModules,
      );
      if (normalized != original) changes[file] = normalized;
    }
    for (final change in changes.entries) {
      await change.key.writeAsString(change.value);
    }
  }

  static List<bool> _swiftCodeMask(String source) {
    final code = List<bool>.filled(source.length, true);
    var i = 0;
    while (i < source.length) {
      if (source.startsWith('//', i)) {
        final end = source.indexOf('\n', i + 2);
        final limit = end < 0 ? source.length : end;
        for (; i < limit; i++) {
          code[i] = false;
        }
        continue;
      }
      if (source.startsWith('/*', i)) {
        var depth = 0;
        do {
          if (source.startsWith('/*', i)) {
            depth++;
            code[i++] = false;
            if (i < source.length) code[i++] = false;
          } else if (source.startsWith('*/', i)) {
            depth--;
            code[i++] = false;
            if (i < source.length) code[i++] = false;
          } else {
            code[i++] = false;
          }
        } while (i < source.length && depth > 0);
        continue;
      }

      var hashes = 0;
      while (i + hashes < source.length && source[i + hashes] == '#') {
        hashes++;
      }
      final quote = i + hashes;
      if (quote < source.length &&
          source[quote] == '"' &&
          (hashes == 0 || quote > i)) {
        final quotes = source.startsWith('"""', quote) ? 3 : 1;
        final delimiter =
            '${quotes == 3 ? '"""' : '"'}${List.filled(hashes, '#').join()}';
        var cursor = quote + quotes;
        while (cursor < source.length) {
          if (source.startsWith(delimiter, cursor)) {
            cursor += delimiter.length;
            break;
          }
          if (hashes == 0 && source[cursor] == r'\') {
            cursor += 2;
          } else {
            cursor++;
          }
        }
        final end = cursor.clamp(0, source.length);
        for (var j = i; j < end; j++) {
          code[j] = false;
        }
        i = end;
        continue;
      }
      i++;
    }
    return code;
  }

  static Future<Map<String, String>> _packageIdentitiesByDirectory(
    String root,
  ) async {
    final identities = <String, String>{};
    final pending = <String>[root];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final directory = p.normalize(pending.removeLast());
      if (!visited.add(directory)) continue;
      final manifestFile = File(p.join(directory, 'Package.swift'));
      if (!manifestFile.existsSync()) continue;
      final manifest = await manifestFile.readAsString();
      for (final call in _swiftCalls(manifest, '.package')) {
        final path = _namedString(call.text, 'path');
        if (path == null) continue;
        final dependencyDirectory = p.normalize(
          p.isAbsolute(path) ? path : p.join(directory, path),
        );
        final dependencyManifest = File(
          p.join(dependencyDirectory, 'Package.swift'),
        );
        final identity =
            _namedString(call.text, 'name') ??
            (dependencyManifest.existsSync()
                ? RegExp(r'Package\s*\(\s*name\s*:\s*"([^"]+)"')
                      .firstMatch(await dependencyManifest.readAsString())
                      ?.group(1)
                : null);
        if (identity != null) identities[dependencyDirectory] = identity;
        pending.add(dependencyDirectory);
      }
    }
    return identities;
  }

  /// Parses remote `.package(url:)` entries out of a Swift manifest.
  ///
  /// Uses parenthesis balancing so nested forms like
  /// `.upToNextMajor(from: "1.0.0")` are not truncated at the inner `)`.
  @visibleForTesting
  static List<SwiftPmPackageDependency> parseUrlPackageDeps(String manifest) {
    final deps = <SwiftPmPackageDependency>[];
    final constants = _manifestStringConstants(manifest);
    var searchFrom = 0;
    final startPattern = RegExp(r'\.package\s*\(');
    while (true) {
      final startMatch = startPattern
          .allMatches(manifest, searchFrom)
          .firstOrNull;
      if (startMatch == null) break;
      final start = startMatch.start;
      final open = startMatch.end - 1; // '('
      final close = _indexOfMatchingParen(manifest, open);
      if (close < 0) break;
      final inner = manifest.substring(open + 1, close);
      final urlMatch = RegExp(
        r'url:\s*(?:"(?<literal>[^"]+)"|(?<constant>[A-Za-z_]\w*)\b(?!\s*\.))',
      ).firstMatch(inner);
      final url =
          urlMatch?.namedGroup('literal') ??
          constants[urlMatch?.namedGroup('constant')];
      if (url == null) {
        searchFrom = close + 1;
        continue;
      }
      final nameMatch = RegExp(r'name:\s*"(?<name>[^"]*)"').firstMatch(inner);
      final name = nameMatch?.namedGroup('name');
      deps.add(
        SwiftPmPackageDependency(
          name: name,
          url: url,
          identity: name ?? packageIdentityFromUrl(url),
          match: manifest.substring(start, close + 1),
        ),
      );
      searchFrom = close + 1;
    }
    return deps;
  }

  /// `let name = "..."` string constants, so `.package(url: name, ...)`
  /// (firebase-ios-sdk's `appMeasurementURL`) can be vendored like literals.
  static Map<String, String> _manifestStringConstants(String manifest) {
    final pattern = RegExp(
      r'\b(?:let|var)\s+(?<name>[A-Za-z_]\w*)\s*(?::\s*String)?\s*=\s*"(?<value>[^"\r\n]*)"',
    );
    return {
      for (final match in pattern.allMatches(manifest))
        match.namedGroup('name')!: match.namedGroup('value')!,
    };
  }

  /// Index of the `)` that closes the `(` at [openIndex], or -1.
  static int _indexOfMatchingParen(String source, int openIndex) {
    var depth = 0;
    var inString = false;
    for (var i = openIndex; i < source.length; i++) {
      final c = source[i];
      if (inString) {
        if (c == r'\' && i + 1 < source.length) {
          i++;
          continue;
        }
        if (c == '"') inString = false;
        continue;
      }
      if (c == '"') {
        inString = true;
        continue;
      }
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// Folder name for a vendored checkout of [url] at [ref].
  @visibleForTesting
  static String vendorPackageDirName(String url, String ref) {
    final safeRef = ref.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final identity = packageIdentityFromUrl(url);
    if (identity == 'firebase-ios-sdk') {
      return 'fb@${safeRef.length > 12 ? safeRef.substring(0, 12) : safeRef}';
    }
    return '$identity@$safeRef';
  }

  /// SwiftPM package identity implied by a git URL (last path segment, no
  /// `.git`). Used as `.package(name:)` so target `package:` references keep
  /// matching after we vendor into a `name@version` directory.
  @visibleForTesting
  static String packageIdentityFromUrl(String url) {
    var identity = Uri.parse(url).pathSegments.lastWhere(
      (segment) => segment.isNotEmpty,
      orElse: () => 'package',
    );
    if (identity.endsWith('.git')) {
      identity = identity.substring(0, identity.length - 4);
    }
    return identity;
  }

  static List<({int start, int end, String text})> _swiftCalls(
    String source,
    String name,
  ) {
    final calls = <({int start, int end, String text})>[];
    final pattern = RegExp('${RegExp.escape(name)}\\s*\\(');
    for (final match in pattern.allMatches(source)) {
      final close = _indexOfMatchingParen(source, match.end - 1);
      if (close >= 0) {
        calls.add((
          start: match.start,
          end: close + 1,
          text: source.substring(match.start, close + 1),
        ));
      }
    }
    return calls;
  }

  static String? _namedString(String call, String name) =>
      RegExp('${RegExp.escape(name)}\\s*:\\s*"([^"]+)"').firstMatch(call)?[1];

  static List<String> _namedStringList(String call, String name) {
    final argument = RegExp('${RegExp.escape(name)}\\s*:').firstMatch(call);
    if (argument == null) return const [];
    final open = call.indexOf('[', argument.end);
    if (open < 0) return const [];
    final close = _indexOfMatchingDelimiter(call, open);
    if (close < 0) return const [];
    return [
      for (final match in RegExp(
        '"([^"]+)"',
      ).allMatches(call.substring(open + 1, close)))
        match[1]!,
    ];
  }

  static int _indexOfMatchingDelimiter(String source, int openIndex) {
    final open = source[openIndex];
    final close = switch (open) {
      '(' => ')',
      '[' => ']',
      '{' => '}',
      _ => '',
    };
    if (close.isEmpty) return -1;
    final code = _swiftCodeMask(source);
    var depth = 0;
    for (var i = openIndex; i < source.length; i++) {
      if (!code[i]) continue;
      if (source[i] == open) {
        depth++;
      } else if (source[i] == close && --depth == 0) {
        return i;
      }
    }
    return -1;
  }

  static ({int open, int close})? _fallbackBlock(String manifest) {
    final marker = manifest.indexOf('products.removeAll()');
    if (marker < 0) return null;
    final open = manifest.lastIndexOf('{', marker);
    if (open < 0) return null;
    final close = _indexOfMatchingDelimiter(manifest, open);
    return close < 0 ? null : (open: open, close: close);
  }

  static Set<String> _consumedProducts(String manifest, String package) {
    final products = <String>{};
    for (final call in _swiftCalls(manifest, '.product')) {
      if (_namedString(call.text, 'package') == package) {
        final name = _namedString(call.text, 'name');
        if (name != null) products.add(name);
      }
    }
    return products;
  }

  static List<String> _topLevelModuleNames(String moduleMap) {
    final code = _swiftCodeMask(moduleMap);
    final names = <String>[];
    var depth = 0;
    var lineStart = 0;
    for (var i = 0; i <= moduleMap.length; i++) {
      if (i == moduleMap.length || moduleMap[i] == '\n') {
        if (depth == 0) {
          final line = moduleMap.substring(lineStart, i);
          final match = RegExp(
            r'^\s*(?:(?:framework|explicit)\s+)?module\s+'
            r'([A-Za-z_][A-Za-z0-9_]*)\s*\{',
          ).firstMatch(line);
          if (match != null) names.add(match[1]!);
        }
        for (var j = lineStart; j < i; j++) {
          if (!code[j]) continue;
          if (moduleMap[j] == '{') depth++;
          if (moduleMap[j] == '}') depth--;
        }
        lineStart = i + 1;
      }
    }
    return names;
  }

  static ({int start, int open, int close})? _moduleBlock(
    String moduleMap,
    String name,
  ) {
    final declaration = RegExp(
      r'^\s*(?:(?:framework|explicit)\s+)?module\s+'
      '${RegExp.escape(name)}\\s*\\{',
      multiLine: true,
    ).firstMatch(moduleMap);
    if (declaration == null) return null;
    final open = moduleMap.indexOf('{', declaration.start);
    final close = _indexOfMatchingDelimiter(moduleMap, open);
    return close < 0
        ? null
        : (start: declaration.start, open: open, close: close);
  }

  static List<({String path, bool directory})> _directModuleHeaders(
    String moduleMap,
    ({int start, int open, int close}) block,
  ) {
    final code = _swiftCodeMask(moduleMap);
    final headers = <({String path, bool directory})>[];
    var depth = 1;
    var lineStart = block.open + 1;
    for (var i = block.open + 1; i <= block.close; i++) {
      if (i != block.close && moduleMap[i] != '\n') continue;
      final line = moduleMap.substring(lineStart, i);
      if (depth == 1) {
        final header = RegExp(
          r'^\s*(?:umbrella\s+)?header\s+"([^"]+)"',
        ).firstMatch(line);
        final umbrella = RegExp(r'^\s*umbrella\s+"([^"]+)"').firstMatch(line);
        if (header != null) {
          headers.add((path: header[1]!, directory: false));
        } else if (umbrella != null) {
          headers.add((path: umbrella[1]!, directory: true));
        }
      }
      for (var j = lineStart; j < i; j++) {
        if (!code[j]) continue;
        if (moduleMap[j] == '{') depth++;
        if (moduleMap[j] == '}') depth--;
      }
      lineStart = i + 1;
    }
    return headers;
  }

  static int _braceDepthAt(String source, int offset) {
    final code = _swiftCodeMask(source);
    var depth = 0;
    for (var i = 0; i < offset; i++) {
      if (!code[i]) continue;
      if (source[i] == '{') depth++;
      if (source[i] == '}') depth--;
    }
    return depth;
  }

  static List<String> _directNestedModules(
    String moduleMap,
    ({int start, int open, int close}) parent,
  ) {
    final nested = <String>[];
    final declaration = RegExp(
      r'^\s*(?:(?:framework|explicit)\s+)?module\s+'
      r'[A-Za-z_][A-Za-z0-9_]*\s*\{',
      multiLine: true,
    );
    for (final match in declaration.allMatches(moduleMap, parent.open + 1)) {
      if (match.start >= parent.close) break;
      if (_braceDepthAt(moduleMap, match.start) != 1) continue;
      final open = moduleMap.indexOf('{', match.start);
      final close = _indexOfMatchingDelimiter(moduleMap, open);
      if (close < 0 || close > parent.close) continue;
      nested.add(moduleMap.substring(match.start, close + 1).trim());
    }
    return nested;
  }

  static bool _ignoredPackageEvidencePath(String packageDir, String path) {
    final relative = p.relative(path, from: packageDir);
    final parts = p.split(relative);
    return parts.any(
      (part) => part == '.git' || part == '.build' || part == '.xcross',
    );
  }

  static String _resolveModuleReference(
    String packageDir,
    String reference, {
    required bool directory,
  }) {
    final normalized = p.normalize(reference);
    final matches = <String>[];
    for (final entity in Directory(
      packageDir,
    ).listSync(recursive: true, followLinks: false)) {
      if (_ignoredPackageEvidencePath(packageDir, entity.path)) continue;
      if (directory ? entity is! Directory : entity is! File) continue;
      final relative = p.normalize(p.relative(entity.path, from: packageDir));
      if (relative == normalized ||
          relative.endsWith('${p.separator}$normalized') ||
          p.basename(relative) == p.basename(normalized)) {
        matches.add(entity.path);
      }
    }
    if (matches.length != 1) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module: ${directory ? 'directory' : 'header'} '
        '"$reference" has ${matches.length} matches in $packageDir.',
      );
    }
    return p.normalize(p.absolute(matches.single));
  }

  static String _absoluteNestedModuleHeaders(String packageDir, String nested) {
    final result = nested.replaceAllMapped(
      RegExp(r'((?:umbrella\s+)?header\s+)"([^"]+)"'),
      (match) {
        final resolved = _resolveModuleReference(
          packageDir,
          match[2]!,
          directory: false,
        );
        return '${match[1]}"${_swiftPath(resolved)}"';
      },
    );
    return result.replaceAllMapped(RegExp(r'(umbrella\s+)"([^"]+)"'), (match) {
      final resolved = _resolveModuleReference(
        packageDir,
        match[2]!,
        directory: true,
      );
      return '${match[1]}"${_swiftPath(resolved)}"';
    });
  }

  /// Adds a dependency-scoped Clang module when a source fallback preserves
  /// its implementation modules but no longer emits a consumed binary module.
  @visibleForTesting
  static Future<String> synthesizeBinaryFallbackCompatibility(
    String manifest, {
    required String packageDir,
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async {
    var result = manifest;
    for (final product in consumedProducts) {
      result = await _synthesizeBinaryFallbackProduct(
        result,
        packageDir: packageDir,
        product: product,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    }
    return result;
  }

  static Future<String> _synthesizeBinaryFallbackProduct(
    String manifest, {
    required String packageDir,
    required String product,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async {
    final fallback = _fallbackBlock(manifest);
    if (fallback == null) return manifest;
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(product)) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM Clang module "$product": the binary '
        'product name is not a Clang module identifier.',
      );
    }

    final normalManifest = manifest.substring(0, fallback.open);
    final binaryTargets = {
      for (final call in _swiftCalls(normalManifest, '.binaryTarget'))
        if (_namedString(call.text, 'name') case final String name) name,
    };
    final binaryBacked = _swiftCalls(normalManifest, '.library').any(
      (call) =>
          _namedString(call.text, 'name') == product &&
          _namedStringList(call.text, 'targets').any(binaryTargets.contains),
    );
    if (!binaryBacked) return manifest;

    final blockText = manifest.substring(fallback.open + 1, fallback.close);
    final synthetic = '_xcross_$product';
    final productCalls = _swiftCalls(blockText, '.library');
    final fallbackProducts = [
      for (final call in productCalls)
        (
          call: call,
          name: _namedString(call.text, 'name'),
          targets: _namedStringList(call.text, 'targets'),
        ),
    ].where((entry) => entry.name != null && entry.targets.isNotEmpty).toList();
    final sourceProducts = [
      for (final entry in fallbackProducts)
        (
          call: entry.call,
          name: entry.name,
          targets: entry.targets.where((name) => name != synthetic).toList(),
        ),
    ].where((entry) => entry.targets.isNotEmpty).toList();
    final matchingProducts = sourceProducts
        .where((entry) => entry.name == product)
        .toList();
    final sourceProduct = matchingProducts.length == 1
        ? matchingProducts.single
        : sourceProducts.length == 1
        ? sourceProducts.single
        : null;
    if (sourceProduct == null) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": the fallback product '
        'is ambiguous (${sourceProducts.map((entry) => entry.name).join(', ')}).',
      );
    }

    final targetCalls = _swiftCalls(blockText, '.target');
    final targets =
        <
          String,
          ({
            String call,
            List<String> dependencies,
            String path,
            String? headers,
            List<String> sources,
            List<String> excludes,
          })
        >{};
    for (final call in targetCalls) {
      final name = _namedString(call.text, 'name');
      if (name == null) continue;
      targets[name] = (
        call: call.text,
        dependencies: _namedStringList(call.text, 'dependencies'),
        path: _namedString(call.text, 'path') ?? p.join('Sources', name),
        headers: _namedString(call.text, 'publicHeadersPath'),
        sources: _namedStringList(call.text, 'sources'),
        excludes: _namedStringList(call.text, 'exclude'),
      );
    }

    final closure = <String>[];
    final visiting = <String>{};
    void visit(String name) {
      if (name == synthetic ||
          !targets.containsKey(name) ||
          !visiting.add(name)) {
        return;
      }
      closure.add(name);
      for (final dependency in targets[name]!.dependencies) {
        visit(dependency);
      }
    }

    for (final target in sourceProduct.targets) {
      visit(target);
    }
    if (closure.isEmpty) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": its fallback target '
        'closure is empty.',
      );
    }

    final headerTargets =
        <({String name, String root, List<String> modules})>[];
    for (final name in closure) {
      final target = targets[name]!;
      if (target.headers == null) continue;
      final root = p.normalize(p.join(packageDir, target.path, target.headers));
      final moduleMap = File(p.join(root, 'module.modulemap'));
      final modules = moduleMap.existsSync()
          ? _topLevelModuleNames(moduleMap.readAsStringSync())
          : [name];
      if (modules.contains(product)) return manifest;
      if (modules.isNotEmpty) {
        headerTargets.add((name: name, root: root, modules: modules));
      }
    }

    final canonicalMaps = <({File file, String text})>[];
    for (final entity in Directory(
      packageDir,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File ||
          _ignoredPackageEvidencePath(packageDir, entity.path) ||
          !(p.basename(entity.path) == 'module.modulemap' ||
              p.basename(entity.path).endsWith('.modulemap'))) {
        continue;
      }
      final text = entity.readAsStringSync();
      if (_moduleBlock(text, product) != null) {
        canonicalMaps.add((file: entity, text: text));
      }
    }
    if (canonicalMaps.length != 1) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": expected one canonical '
        'module map, found ${canonicalMaps.length}.',
      );
    }
    final canonical = canonicalMaps.single;
    final canonicalBlock = _moduleBlock(canonical.text, product)!;
    final publicHeaders = [
      for (final header in _directModuleHeaders(canonical.text, canonicalBlock))
        _resolveModuleReference(
          packageDir,
          header.path,
          directory: header.directory,
        ),
    ];
    final publicModules = headerTargets.where((target) {
      return publicHeaders.every(
        (header) =>
            p.equals(header, target.root) || p.isWithin(target.root, header),
      );
    }).toList();
    if (publicModules.length != 1 || publicModules.single.modules.length != 1) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": the fallback public '
        'header module is ambiguous.',
      );
    }

    final swiftModules = <String>[];
    for (final name in closure) {
      final target = targets[name]!;
      final root = Directory(p.join(packageDir, target.path));
      if (!root.existsSync()) continue;
      final sourceRoots = target.sources.isEmpty
          ? [root.path]
          : [for (final source in target.sources) p.join(root.path, source)];
      final hasSwift = sourceRoots.any((sourceRoot) {
        final directory = Directory(sourceRoot);
        if (directory.existsSync()) {
          return directory.listSync(recursive: true, followLinks: false).any((
            entity,
          ) {
            if (entity is! File || !entity.path.endsWith('.swift')) {
              return false;
            }
            final relative = p.relative(entity.path, from: root.path);
            return !target.excludes.any(
              (excluded) =>
                  p.equals(relative, excluded) ||
                  p.isWithin(excluded, relative),
            );
          });
        }
        return File(sourceRoot).path.endsWith('.swift') &&
            File(sourceRoot).existsSync();
      });
      if (hasSwift) swiftModules.add(name);
    }
    if (fallbackSwiftModules != null) {
      fallbackSwiftModules[product] = swiftModules;
    }

    final compatibilityDir = p.join(packageDir, '.xcross', synthetic);
    final includeDir = p.join(compatibilityDir, 'include');
    final nested = [
      for (final module in _directNestedModules(canonical.text, canonicalBlock))
        _absoluteNestedModuleHeaders(packageDir, module),
    ];
    final nestedNames = [
      for (final module in nested) ..._topLevelModuleNames(module),
    ];
    final indentedNested = nested
        .map(
          (module) => module
              .replaceFirst(RegExp(r'\{'), '{\n  header "$product.h"')
              .split('\n')
              .map((line) => '  $line')
              .join('\n'),
        )
        .join('\n');
    final moduleMap = StringBuffer()
      ..writeln('module $product {')
      ..writeln('  header "$product.h"')
      ..writeln('  export *');
    for (final name in nestedNames) {
      moduleMap.writeln('  export $name');
    }
    if (indentedNested.isNotEmpty) moduleMap.writeln(indentedNested);
    moduleMap.writeln('}');

    await Directory(includeDir).create(recursive: true);
    final shim = StringBuffer()
      ..writeln('@import ${publicModules.single.modules.single};');
    // The fallback's Swift half completes the Objective-C surface: the
    // headers refer to types the Swift target declares, so a consumer that
    // sees the headers alone imports those declarations as incomplete and
    // loses every member mentioning them. Swift emits an Objective-C
    // interop header for such a target, and SwiftPM puts it on the include
    // path of the targets that depend on it. Prefer that header, because a
    // bare `@import` of a Swift module only resolves once that module is
    // built, which is not the case while Swift builds this very module.
    for (final module in swiftModules) {
      shim
        ..writeln('#if __has_include("$module-Swift.h")')
        ..writeln('#import "$module-Swift.h"')
        ..writeln('#elif !defined(__swift__)')
        ..writeln('@import $module;')
        ..writeln('#endif');
    }
    await _writeStable(p.join(includeDir, '$product.h'), shim.toString());
    await _writeStable(
      p.join(includeDir, 'module.modulemap'),
      moduleMap.toString(),
    );
    await _writeStable(
      p.join(compatibilityDir, '$synthetic.m'),
      '#import "$product.h"\n',
    );

    final syntheticCount = fallbackProducts
        .singleWhere((entry) => entry.call.start == sourceProduct.call.start)
        .targets
        .where((name) => name == synthetic)
        .length;
    var rewrittenBlock = blockText;
    if (sourceProduct.name == product && syntheticCount != 1) {
      final targetsPattern = RegExp(r'targets\s*:\s*\[([^\]]*)\]');
      final normalizedTargets = [
        ...sourceProduct.targets,
        synthetic,
      ].map((name) => '"$name"').join(', ');
      final updatedProduct = sourceProduct.call.text.replaceFirst(
        targetsPattern,
        'targets: [$normalizedTargets]',
      );
      rewrittenBlock = rewrittenBlock.replaceRange(
        sourceProduct.call.start,
        sourceProduct.call.end,
        updatedProduct,
      );
    }
    final dependencyList = closure.map((name) => '"$name"').join(', ');
    final additions = StringBuffer();
    if (sourceProduct.name != product &&
        !fallbackProducts.any((entry) => entry.name == product)) {
      additions.writeln(
        '    products.append(.library(name: "$product", '
        'targets: ["$synthetic"]))',
      );
    }
    if (!targets.containsKey(synthetic)) {
      additions.writeln(
        '    targets.append(.target(name: "$synthetic", '
        'dependencies: [$dependencyList], path: ".xcross/$synthetic", '
        'publicHeadersPath: "include"))',
      );
    }
    rewrittenBlock = '${rewrittenBlock.trimRight()}\n$additions';
    return manifest.replaceRange(
      fallback.open + 1,
      fallback.close,
      rewrittenBlock,
    );
  }

  @visibleForTesting
  static Map<String, String> dependencyRefsFromPackageResolved(String output) {
    final resolved = jsonDecode(output) as Map<String, dynamic>;
    return {
      for (final pinValue in resolved['pins'] as List<dynamic>? ?? const [])
        if (pinValue case {
          'location': final String location,
          'state': {'revision': final String revision},
        })
          _canonicalGitUrl(location): revision,
    };
  }

  static String _canonicalGitUrl(String url) {
    var canonical = url.replaceFirst(RegExp(r'/+$'), '');
    if (canonical.toLowerCase().endsWith('.git')) {
      canonical = canonical.substring(0, canonical.length - 4);
    }
    final parsed = Uri.tryParse(canonical);
    if (parsed == null || !parsed.hasScheme) return canonical;
    return parsed
        .replace(
          scheme: parsed.scheme.toLowerCase(),
          host: parsed.host.toLowerCase(),
        )
        .toString();
  }

  static Future<String> _dependencyEvaluationKey(
    String manifest,
    String packageDirectory,
  ) async {
    final variants = <String>[];
    final directory = Directory(packageDirectory);
    if (directory.existsSync()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('Package@') && name.endsWith('.swift')) {
          variants.add('$name\u0000${await entity.readAsString()}');
        }
      }
    }
    variants.sort();
    return sha256
        .convert(
          utf8.encode(
            [
              'xcross-dependency-evaluation-v1',
              manifest,
              ...variants,
            ].join('\u0000'),
          ),
        )
        .toString();
  }

  @visibleForTesting
  static List<SwiftPmBinaryArtifactProvenance> scanBinaryArtifactProvenance({
    required String packageIdentity,
    required String manifestPath,
    required String manifest,
  }) => [
    for (final target in SwiftPmBinaryTargetManifest.discover(manifest))
      SwiftPmBinaryArtifactProvenance(
        packageIdentity: packageIdentity,
        target: target,
        manifestPath: manifestPath,
      ),
  ];

  @visibleForTesting
  static SwiftPmBinaryArtifactProvenance? matchBinaryArtifactProvenance({
    required String artifactPath,
    required String artifactsRoot,
    required Iterable<SwiftPmBinaryArtifactProvenance> provenance,
    bool? windows,
  }) {
    final relative = p.split(p.relative(artifactPath, from: artifactsRoot));
    if (relative.length < 2 ||
        _swiftPmComponent(relative.first, windows: windows) == 'extract') {
      return null;
    }
    final identity = _swiftPmComponent(relative[0], windows: windows);
    final target = _swiftPmComponent(relative[1], windows: windows);
    final matches = provenance
        .where(
          (candidate) =>
              _swiftPmComponent(candidate.packageIdentity, windows: windows) ==
                  identity &&
              _swiftPmComponent(candidate.target.name, windows: windows) ==
                  target,
        )
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  static String _swiftPmComponent(String value, {bool? windows}) =>
      (windows ?? Platform.isWindows) ? value.toLowerCase() : value;

  @visibleForTesting
  static String binaryArtifactAttemptKey(
    SwiftPmBinaryArtifactProvenance provenance, {
    bool? windows,
  }) => [
    _swiftPmComponent(provenance.packageIdentity, windows: windows),
    _swiftPmComponent(provenance.target.name, windows: windows),
    provenance.target.checksum.toLowerCase(),
  ].join('\u0000');

  static Future<List<SwiftPmBinaryArtifactProvenance>>
  _binaryArtifactProvenance(
    String packageDirectory,
    String scratchPath,
    List<SwiftPmPackageDependency> dependencies,
  ) async {
    final result = <SwiftPmBinaryArtifactProvenance>[];
    final packageRoot = Directory(packageDirectory);
    final checkoutRoot = p.join(scratchPath, 'checkouts');
    final roots = <String, String?>{packageRoot.path: null};
    for (final dependency in dependencies) {
      roots[p.join(checkoutRoot, dependency.identity)] = dependency.identity;
      roots[p.join(checkoutRoot, packageIdentityFromUrl(dependency.url))] =
          dependency.identity;
    }
    for (final entry in roots.entries) {
      final root = Directory(entry.key);
      if (!root.existsSync()) continue;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name != 'Package.swift' &&
            !(name.startsWith('Package@') && name.endsWith('.swift'))) {
          continue;
        }
        final manifest = await entity.readAsString();
        final declaredName = RegExp(
          r'Package\s*\(\s*name\s*:\s*"([^"]+)"',
        ).firstMatch(manifest)?.group(1);
        final identity = entry.value ?? declaredName;
        if (identity == null) continue;
        result.addAll(
          scanBinaryArtifactProvenance(
            packageIdentity: identity,
            manifestPath: entity.path,
            manifest: manifest,
          ),
        );
      }
    }
    return result;
  }

  @visibleForTesting
  static Future<bool> recoverBootstrapBinaryArtifacts({
    required String scratchPath,
    required String binaryArtifactStore,
    required Iterable<SwiftPmBinaryArtifactProvenance> provenance,
    required SwiftPmBinaryAttemptState attemptState,
    bool swiftPmArtifactJunctionCapability = false,
    bool? windows,
  }) async {
    if (!(windows ?? Platform.isWindows)) return false;
    final artifactsRoot = p.join(scratchPath, 'artifacts');
    final artifacts = Directory(artifactsRoot);
    if (!artifacts.existsSync()) return false;
    final preparer = SwiftPmBinaryArtifactPreparer(
      store: SwiftPmBinaryArtifactStore(binaryArtifactStore),
    );
    final candidates =
        <
          String,
          List<
            ({Directory directory, SwiftPmBinaryArtifactProvenance provenance})
          >
        >{};
    for (final package in artifacts.listSync(followLinks: false)) {
      if (package is! Directory ||
          _swiftPmComponent(p.basename(package.path), windows: windows) ==
              'extract') {
        continue;
      }
      for (final targetDirectory in package.listSync(followLinks: false)) {
        if (targetDirectory is! Directory) continue;
        final match = matchBinaryArtifactProvenance(
          artifactPath: targetDirectory.path,
          artifactsRoot: artifactsRoot,
          provenance: provenance,
          windows: windows,
        );
        if (match == null) continue;
        final key = binaryArtifactAttemptKey(match, windows: windows);
        (candidates[key] ??= []).add((
          directory: targetDirectory,
          provenance: match,
        ));
      }
    }

    var recovered = false;
    for (final candidateList in candidates.values) {
      if (candidateList.length != 1) continue;
      final candidate = candidateList.single;
      final key = binaryArtifactAttemptKey(
        candidate.provenance,
        windows: windows,
      );
      if (attemptState.bootstrapRecovered.contains(key)) continue;
      final completeArtifacts = candidate.directory
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where(
            (directory) =>
                directory.path.toLowerCase().endsWith('.xcframework'),
          );
      var hasFinalArtifact = false;
      for (final artifact in completeArtifacts) {
        if (await hasCompleteSwiftPmArtifact(artifact)) {
          hasFinalArtifact = true;
          break;
        }
      }
      if (hasFinalArtifact) continue;
      final archives = candidate.directory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.zip'));
      final verified = <SwiftPmPreparedBinaryArtifact>[];
      for (final archive in archives) {
        try {
          verified.add(
            SwiftPmPreparedBinaryArtifact(
              target: candidate.provenance.target,
              entry: await preparer.prepareDownloadedArchive(
                target: candidate.provenance.target,
                archive: archive,
              ),
            ),
          );
        } on FlutterBuildError catch (error) {
          if (error.isSecurityFailure) rethrow;
          continue;
        } on Object {
          continue;
        }
      }
      if (verified.length != 1) continue;
      final prepared = verified.single;
      final destination = p.join(
        candidate.directory.path,
        p.basename(prepared.entry.artifactPath),
      );
      if (swiftPmArtifactJunctionCapability) {
        try {
          await preparer.createBinaryArtifactJunction(
            alias: destination,
            target: prepared.entry.artifactPath,
          );
        } on FileSystemException {
          if (attemptState.copied.contains(key)) continue;
          attemptState.copied.add(key);
          await preparer.materializeBinaryArtifact(
            source: prepared.entry.artifactPath,
            destination: destination,
          );
        }
      } else {
        if (attemptState.copied.contains(key)) continue;
        attemptState.copied.add(key);
        await preparer.materializeBinaryArtifact(
          source: prepared.entry.artifactPath,
          destination: destination,
        );
      }
      attemptState.bootstrapRecovered.add(key);
      recovered = true;
    }
    return recovered;
  }

  @visibleForTesting
  static Future<bool> hasCompleteSwiftPmArtifact(Directory artifact) async {
    final info = File(p.join(artifact.path, 'Info.plist'));
    if (!info.existsSync()) return false;
    try {
      final value = PropertyListSerialization.propertyListWithString(
        await info.readAsString(),
      );
      if (value is! Map) return false;
      final libraries = value['AvailableLibraries'];
      if (libraries is! List) return false;
      for (final value in libraries) {
        if (value is! Map || value['SupportedPlatform'] != 'ios') continue;
        final architectures = value['SupportedArchitectures'];
        final identifier = value['LibraryIdentifier'];
        final libraryPath = value['LibraryPath'];
        if (architectures is! List ||
            !architectures.contains('arm64') ||
            identifier is! String ||
            identifier.isEmpty ||
            libraryPath is! String ||
            libraryPath.isEmpty) {
          continue;
        }
        if (FileSystemEntity.typeSync(
              p.join(artifact.path, identifier, libraryPath),
            ) !=
            FileSystemEntityType.notFound) {
          return true;
        }
      }
    } on Object {
      return false;
    }
    return false;
  }

  @visibleForTesting
  static Future<Map<String, String>> evaluateDependencyRefsWithRecovery(
    String packageDirectory, {
    required Future<void> Function(String packageDirectory) resolve,
    required Future<bool> Function(
      String packageDirectory,
      SwiftPmBinaryAttemptState attemptState,
    )
    recover,
    required SwiftPmBinaryAttemptState attemptState,
  }) async {
    final resolvedFile = File(p.join(packageDirectory, 'Package.resolved'));
    if (resolvedFile.existsSync()) await resolvedFile.delete();
    try {
      await resolve(packageDirectory);
    } on Object {
      if (!await recover(packageDirectory, attemptState)) rethrow;
      await resolve(packageDirectory);
    }
    try {
      return dependencyRefsFromPackageResolved(
        await resolvedFile.readAsString(),
      );
    } on Object catch (error) {
      throw FlutterBuildError('Cannot read ${resolvedFile.path}: $error');
    }
  }

  static Future<Map<String, String>> _evaluatedDependencyRefs(
    String packageDirectory,
    Future<String> Function(String name) locateTool, {
    Future<void> Function(String packageDirectory)? resolve,
    Future<bool> Function(
      String packageDirectory,
      SwiftPmBinaryAttemptState attemptState,
    )?
    recover,
    SwiftPmBinaryAttemptState? attemptState,
    String? scratchPath,
    String? binaryArtifactStore,
    String? binaryArtifactFallback,
    bool swiftPmArtifactJunctionCapability = false,
    List<SwiftPmPackageDependency> dependencies = const [],
  }) async {
    final swift = await locateTool(
      Platform.isWindows ? 'swift-package' : 'swift',
    );
    final runResolve =
        resolve ??
        (directory) async {
          final result = await ProcessRunner.run(swift, [
            if (!Platform.isWindows) 'package',
            '--package-path',
            directory,
            'resolve',
          ]);
          if (result.exitCode != 0) {
            throw FlutterBuildError(
              'Cannot resolve SwiftPM dependencies in $directory:\n'
              '${result.stderr.trim()}',
            );
          }
        };
    final canRecover =
        recover != null ||
        (Platform.isWindows &&
            scratchPath != null &&
            binaryArtifactStore != null &&
            binaryArtifactFallback != null);
    final scannedProvenance = recover == null && canRecover
        ? await _binaryArtifactProvenance(
            packageDirectory,
            scratchPath!,
            dependencies,
          )
        : null;
    return evaluateDependencyRefsWithRecovery(
      packageDirectory,
      resolve: runResolve,
      recover:
          recover ??
          (_, state) => canRecover
              ? recoverBootstrapBinaryArtifacts(
                  scratchPath: scratchPath!,
                  binaryArtifactStore: binaryArtifactStore!,
                  provenance: scannedProvenance!,
                  attemptState: state,
                  swiftPmArtifactJunctionCapability:
                      swiftPmArtifactJunctionCapability,
                )
              : Future<bool>.value(false),
      attemptState: attemptState ?? SwiftPmBinaryAttemptState(),
    );
  }

  /// Clones each `.package(url:)` dependency under [vendorDir], normalizes its
  /// host manifests, and rewrites the plugin manifest to `.package(path:)`.
  @visibleForTesting
  static Future<String> vendorUrlPackagesAsPathDeps(
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
    final deps = parseUrlPackageDeps(manifest);
    if (deps.isEmpty) return manifest;

    final locate = locateTool ?? ProcessRunner.locateTool;
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
            : _evaluatedDependencyRefs(
                directory,
                locate,
                scratchPath: scratchPath,
                binaryArtifactStore: binaryArtifactStore,
                binaryArtifactFallback: binaryArtifactFallback,
                swiftPmArtifactJunctionCapability:
                    swiftPmArtifactJunctionCapability,
                dependencies: dependencies,
              );
    final evaluationKey = await _dependencyEvaluationKey(
      manifest,
      packageDirectory,
    );
    late final Map<String, String> evaluatedRefs;
    if (evaluationCache == null) {
      evaluatedRefs = await evaluate(
        packageDirectory,
        scratchPath: scratchPath,
        binaryArtifactStore: binaryArtifactStore,
        binaryArtifactFallback: binaryArtifactFallback,
        swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
        packageLocalArtifactJunctionCapability:
            packageLocalArtifactJunctionCapability,
        dependencies: deps,
      );
    } else {
      final pending = evaluationCache.putIfAbsent(
        evaluationKey,
        () => evaluate(
          packageDirectory,
          scratchPath: scratchPath,
          binaryArtifactStore: binaryArtifactStore,
          binaryArtifactFallback: binaryArtifactFallback,
          swiftPmArtifactJunctionCapability: swiftPmArtifactJunctionCapability,
          packageLocalArtifactJunctionCapability:
              packageLocalArtifactJunctionCapability,
          dependencies: deps,
        ),
      );
      try {
        evaluatedRefs = await pending;
      } on Object {
        if (identical(evaluationCache[evaluationKey], pending)) {
          final _ = evaluationCache.remove(evaluationKey);
        }
        rethrow;
      }
    }
    late final String git;
    try {
      git = await locate('git');
    } on CliError {
      throw FlutterBuildError(
        'Git is required to vendor SwiftPM URL dependencies '
        '(e.g. Firebase or sentry-cocoa). Install Git and ensure it is on PATH.',
      );
    }

    final clone = clonePackage ?? _cloneGitPackage;

    Future<void> checkout(String url, String ref, String destination) async {
      if (checkoutCache == null) {
        await clone(git, url, ref, destination);
        return;
      }
      final key = p.normalize(destination);
      final pending = checkoutCache.putIfAbsent(
        key,
        () => clone(git, url, ref, destination),
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

    return _vendorUrlDeps(
      manifest,
      vendorDir: vendorDir,
      evaluatedRefs: evaluatedRefs,
      checkout: checkout,
      vendored: <String>{},
      requireResolvedRefs: true,
      fallbackSwiftModules: fallbackSwiftModules,
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
  static Future<String> _vendorUrlDeps(
    String manifest, {
    required String vendorDir,
    required Map<String, String> evaluatedRefs,
    required Future<void> Function(String url, String ref, String destination)
    checkout,
    required Set<String> vendored,
    required bool requireResolvedRefs,
    Map<String, List<String>>? fallbackSwiftModules,
    Map<String, Map<String, List<String>>>? normalizationCache,
  }) async {
    final deps = parseUrlPackageDeps(manifest);
    if (deps.isEmpty) return manifest;

    var result = manifest;
    for (final dep in deps) {
      final ref = evaluatedRefs[_canonicalGitUrl(dep.url)];
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
      final dirName = vendorPackageDirName(dep.url, ref);
      // Always set name: — without it SwiftPM uses the directory basename
      // (`pkg@1.2.3`), which breaks `.product(..., package: "pkg")`.
      final identity = dep.identity;
      final destination = p.join(vendorDir, dirName);
      if (vendored.add(p.normalize(destination))) {
        await checkout(dep.url, ref, destination);
        final consumedProducts = _consumedProducts(manifest, identity);

        final cacheKey = [
          p.normalize(destination),
          ...(consumedProducts.toList()..sort()),
        ].join('\u0000');
        final cachedModules = normalizationCache?[cacheKey];
        if (cachedModules == null) {
          final existingModules =
              fallbackSwiftModules?.keys.toSet() ?? const {};
          await _normalizeVendoredPackageManifests(
            destination,
            consumedProducts: consumedProducts,
            fallbackSwiftModules: fallbackSwiftModules,
            rewriteDependencies: (nested) => _vendorUrlDeps(
              nested,
              vendorDir: vendorDir,
              evaluatedRefs: evaluatedRefs,
              checkout: checkout,
              vendored: vendored,
              requireResolvedRefs: false,
              fallbackSwiftModules: fallbackSwiftModules,
              normalizationCache: normalizationCache,
            ),
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
      final pathDep =
          '.package(name: "$identity", '
          'path: "${_swiftPath(destination)}")';
      result = result.replaceFirst(dep.match, pathDep);
    }
    return result;
  }

  /// Replaces mode-120000 checkout placeholders produced by Git for Windows
  /// with hard links to files or copies of directory targets.

  @visibleForTesting
  static Future<bool> materializeCheckoutSymlinks(
    String scratchPath, {
    String git = 'git',
  }) async {
    final gitExecutable = git == 'git'
        ? await ProcessRunner.locateTool(git)
        : git;
    final checkouts = Directory(p.join(scratchPath, 'checkouts'));
    if (!checkouts.existsSync()) return false;
    var changed = false;
    await for (final repo in checkouts.list(followLinks: false)) {
      if (repo is! Directory) continue;
      final index = await ProcessRunner.run(gitExecutable, [
        '-C',
        repo.path,
        'ls-files',
        '-s',
        '-z',
      ]);
      if (index.exitCode != 0) {
        throw FlutterBuildError(
          'Could not inspect SwiftPM checkout ${repo.path}: ${index.stderr}',
        );
      }
      final stampName = sha256.convert(utf8.encode(repo.path)).toString();
      changed =
          await _materializeGitSymlinks(
            repo.path,
            index.stdout,
            gitExecutable,
            File(p.join(scratchPath, '.xcross-symlinks', stampName)),
          ) ||
          changed;
    }
    return changed;
  }

  static Future<bool> _materializeGitSymlinks(
    String repoPath,
    String index,
    String git,
    File stamp,
  ) async {
    final root = p.normalize(p.absolute(repoPath));
    final links = <String, String>{};
    for (final record in index.split('\u0000')) {
      final match = RegExp(
        r'^120000 ([0-9a-f]+) \d+\t(.*)$',
      ).firstMatch(record);
      if (match != null) {
        links[p.normalize(p.join(root, match[2]))] = match[1]!;
      }
    }

    final fingerprint = sha256
        .convert(
          utf8.encode(
            'xcross-symlink-materialization-v1\u0000'
            '${Platform.operatingSystem}\u0000$index',
          ),
        )
        .toString();
    if (stamp.existsSync() && await stamp.readAsString() == fingerprint) {
      return false;
    }

    final blobs = await _readGitBlobs(repoPath, links.values.toSet(), git);
    final targets = <String, String>{
      for (final link in links.entries)
        link.key: utf8
            .decode(blobs[link.value]!)
            .replaceFirst(RegExp(r'[\r\n]+$'), ''),
    };

    final resolved = <String, String>{};
    String resolve(String source, Set<String> chain) {
      if (!chain.add(source)) {
        throw FlutterBuildError('Symlink cycle in SwiftPM checkout: $source');
      }
      final targetText = targets[source]!;
      if (p.isAbsolute(targetText)) {
        throw FlutterBuildError(
          'Symlink escapes SwiftPM checkout: $source -> $targetText',
        );
      }
      final target = p.normalize(p.absolute(p.dirname(source), targetText));
      if (target != root && !p.isWithin(root, target)) {
        throw FlutterBuildError(
          'Symlink escapes SwiftPM checkout: $source -> $targetText',
        );
      }
      final result = links.containsKey(target)
          ? resolve(target, chain)
          : target;
      chain.remove(source);
      return result;
    }

    for (final link in links.keys) {
      resolved[link] = resolve(link, <String>{});
    }

    final materializing = <String>{};
    final materialized = <String>{};
    var changed = false;
    Future<void> materialize(String link) async {
      if (materialized.contains(link)) return;
      if (!materializing.add(link)) {
        throw FlutterBuildError('Symlink cycle in SwiftPM checkout: $link');
      }
      final target = resolved[link]!;
      if (Directory(target).existsSync()) {
        for (final nested in links.keys) {
          if (p.isWithin(target, nested)) await materialize(nested);
        }
      }
      // Re-materializing an already-correct placeholder would refresh its
      // timestamp and rebuild every dependent, so each shape is checked
      // before it is rewritten.
      if (Directory(target).existsSync()) {
        await _clearPlaceholderAttributes(link);
        final existingType = FileSystemEntity.typeSync(
          link,
          followLinks: false,
        );
        await _deleteUnless(link, FileSystemEntityType.directory);
        changed =
            await _syncDirectory(target, link) ||
            existingType != FileSystemEntityType.directory ||
            changed;
      } else if (File(target).existsSync()) {
        changed = await _materializeFileLink(link, target) || changed;
      } else {
        throw FlutterBuildError(
          'Symlink target does not exist in SwiftPM checkout: $link -> $target',
        );
      }
      materializing.remove(link);
      materialized.add(link);
    }

    for (final link in links.keys) {
      await materialize(link);
    }
    await stamp.parent.create(recursive: true);
    await stamp.writeAsString(fingerprint);
    return changed;
  }

  static Future<Map<String, List<int>>> _readGitBlobs(
    String repoPath,
    Set<String> objectIds,
    String git,
  ) async {
    if (objectIds.isEmpty) return const {};
    final process = await ProcessRunner.start(git, [
      '-C',
      repoPath,
      'cat-file',
      '--batch',
    ]);
    for (final objectId in objectIds) {
      process.stdin.writeln(objectId);
    }
    await process.stdin.close();
    final output = await process.stdout.fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    final error = await process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw FlutterBuildError(
        'Could not read symlink targets in SwiftPM checkout $repoPath: $error',
      );
    }

    var offset = 0;
    final blobs = <String, List<int>>{};
    for (final requested in objectIds) {
      final newline = output.indexOf(10, offset);
      if (newline < 0) {
        throw FlutterBuildError(
          'Malformed Git object response in SwiftPM checkout $repoPath.',
        );
      }
      final header = utf8.decode(output.sublist(offset, newline));
      final fields = header.split(' ');
      if (fields.length != 3 || fields[1] != 'blob') {
        throw FlutterBuildError(
          'Could not read symlink target $requested in SwiftPM checkout '
          '$repoPath: $header',
        );
      }
      final size = int.tryParse(fields[2]);
      if (size == null || size < 0 || newline + 1 + size >= output.length) {
        throw FlutterBuildError(
          'Malformed Git object response in SwiftPM checkout $repoPath.',
        );
      }
      final end = newline + 1 + size;
      blobs[requested] = output.sublist(newline + 1, end);
      if (output[end] != 10) {
        throw FlutterBuildError(
          'Malformed Git object response in SwiftPM checkout $repoPath.',
        );
      }
      offset = end + 1;
    }
    return blobs;
  }

  /// Windows source for a header placeholder that keeps one Clang file
  /// identity, or null when [link] is not a header.
  ///
  /// Packages publish umbrella directories by symlinking headers to a
  /// source tree, so the same header is reachable under two paths. Clang
  /// suppresses the second inclusion by file identity, and on POSIX a
  /// symlink shares one. Windows checkouts cannot use symlinks without
  /// elevation, and Clang treats the two names of a hard link as separate
  /// identities, so a header without an include guard is parsed twice and
  /// every declaration in it collides with itself. Forwarding to the
  /// target instead leaves exactly one file to parse under either path.
  static String? _headerForwarder(String link, String target) {
    const headerExtensions = {'.h', '.hh', '.hpp', '.hxx', '.h++'};
    if (!headerExtensions.contains(p.extension(link).toLowerCase())) {
      return null;
    }
    final relative = p.relative(target, from: p.dirname(link));
    return '#include "${relative.replaceAll(r'\', '/')}"\n';
  }

  /// Replaces a file placeholder with its materialized form: a forwarding
  /// header, a hard link on Windows, or a plain copy elsewhere. A
  /// placeholder whose content already matches is left untouched.
  static Future<bool> _materializeFileLink(String link, String target) async {
    if (!Platform.isWindows) {
      return _syncFile(File(target), link);
    }
    final forwarder = _headerForwarder(link, target);
    final expected = forwarder != null
        ? utf8.encode(forwarder)
        : await File(target).readAsBytes();
    final existing = File(link);
    if (existing.existsSync() &&
        _sameBytes(await existing.readAsBytes(), expected)) {
      return false;
    }
    await _clearPlaceholderAttributes(link);
    await _deleteEntity(link);
    if (forwarder != null) {
      await existing.writeAsString(forwarder);
      return true;
    }
    final result = await ProcessRunner.run(
      await ProcessRunner.locateTool('cmd.exe'),
      ['/d', '/c', 'mklink', '/H', link, target],
    );
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not create hard link: ${result.stderr}',
        link,
      );
    }
    return true;
  }

  /// Git for Windows checks out symlink placeholders read-only.
  static Future<void> _clearPlaceholderAttributes(String path) async {
    if (!Platform.isWindows) return;
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final result = await ProcessRunner.run(
      await ProcessRunner.locateTool('attrib'),
      ['-R', path],
    );
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not clear read-only checkout placeholder: ${result.stderr}',
        path,
      );
    }
  }

  static Future<void> _cloneGitPackage(
    String git,
    String url,
    String ref,
    String destination,
  ) async {
    final destDir = Directory(destination);
    final environment = swiftProcessEnvironment(windows: Platform.isWindows);
    final gitConfig = Platform.isWindows
        ? const ['-c', 'core.longpaths=true']
        : const <String>[];
    if (File(p.join(destination, '.git')).existsSync() ||
        Directory(p.join(destination, '.git')).existsSync()) {
      final head = await ProcessRunner.run(git, [
        ...gitConfig,
        '-C',
        destination,
        'rev-parse',
        '--verify',
        'HEAD',
      ], environment: environment);
      if (head.exitCode == 0 &&
          head.stdout.trim().toLowerCase() == ref.toLowerCase()) {
        await ProcessRunner.runChecked(
          git,
          [...gitConfig, '-C', destination, 'reset', '--hard', 'HEAD'],
          environment: environment,
          label: 'git reset vendored package',
        );
        return;
      }
    }
    await _deleteEntity(destination);
    await destDir.parent.create(recursive: true);

    final shallow = await ProcessRunner.run(git, [
      ...gitConfig,
      'clone',
      '--depth',
      '1',
      '--branch',
      ref,
      url,
      destination,
    ], environment: environment);
    if (shallow.exitCode == 0) return;

    await _deleteEntity(destination);
    await Directory(destination).create(recursive: true);
    final init = await ProcessRunner.run(git, [
      ...gitConfig,
      '-C',
      destination,
      'init',
    ], environment: environment);
    final fetch = init.exitCode == 0
        ? await ProcessRunner.run(git, [
            ...gitConfig,
            '-C',
            destination,
            'fetch',
            '--depth',
            '1',
            url,
            ref,
          ], environment: environment)
        : init;
    final checkout = fetch.exitCode == 0
        ? await ProcessRunner.run(git, [
            ...gitConfig,
            '-C',
            destination,
            'checkout',
            '--detach',
            'FETCH_HEAD',
          ], environment: environment)
        : fetch;
    if (checkout.exitCode == 0) return;

    await _deleteEntity(destination);
    await ProcessRunner.runChecked(
      git,
      [...gitConfig, 'clone', url, destination],
      environment: environment,
      label: 'git clone $url',
    );
    await ProcessRunner.runChecked(
      git,
      [...gitConfig, '-C', destination, 'checkout', ref],
      environment: environment,
      label: 'git checkout $ref',
    );
  }

  static Future<bool> _normalizeVendoredPackageManifests(
    String packageDir, {
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
    Future<String> Function(String manifest)? rewriteDependencies,
  }) async {
    var changed = false;
    await for (final entity in Directory(packageDir).list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name != 'Package.swift' &&
          !(name.startsWith('Package@') && name.endsWith('.swift'))) {
        continue;
      }
      final original = await entity.readAsString();
      var normalized = await synthesizeBinaryFallbackCompatibility(
        normalizeHostManifest(original),
        packageDir: packageDir,
        consumedProducts: consumedProducts,
        fallbackSwiftModules: fallbackSwiftModules,
      );
      if (rewriteDependencies != null) {
        normalized = await rewriteDependencies(normalized);
      }
      if (normalized != original) {
        await _clearPlaceholderAttributes(entity.path);
        await entity.writeAsString(normalized);
        changed = true;
      }
    }
    return changed;
  }

  /// `Plugins/Package.swift` contents — aggregates every plugin's SPM package
  /// into one dynamic library product depending on [frameworkDir]'s
  /// `FlutterFramework` package plus every entry in [plugins].
  @visibleForTesting
  static String pluginsManifest(
    List<IosPlugin> plugins,
    String frameworkDir, {
    required IosDeploymentTarget deploymentTarget,
    Map<String, String>? pluginPackageDirs,
  }) {
    final dependencies = StringBuffer()
      ..writeln(
        '        .package(name: "$_flutterFrameworkPackageName", '
        'path: "${_swiftPath(frameworkDir)}"),',
      );
    for (final plugin in plugins) {
      final packageDir =
          pluginPackageDirs?[plugin.name] ?? plugin.swiftPackageDir;
      dependencies.writeln(
        '        .package(name: "${plugin.name}", '
        'path: "${_swiftPath(packageDir)}"),',
      );
    }

    final targetDependencies = StringBuffer()
      ..writeln(
        '                .product(name: "$_flutterFrameworkPackageName", '
        'package: "$_flutterFrameworkPackageName"),',
      );
    for (final plugin in plugins) {
      targetDependencies.writeln(
        '                .product(name: "${_hyphenate(plugin.name)}", '
        'package: "${plugin.name}"),',
      );
    }

    return '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$_pluginsProductName",
    platforms: [
        .iOS("${deploymentTarget.version}")
    ],
    products: [
        .library(name: "$_pluginsProductName", type: .dynamic, targets: ["$_pluginsProductName"])
    ],
    dependencies: [
$dependencies    ],
    targets: [
        .target(
            name: "$_pluginsProductName",
            dependencies: [
$targetDependencies            ]
        )
    ]
)
''';
  }

  /// `GeneratedPluginRegistrant.swift` contents — imports and registers each
  /// plugin that has a non-null `pluginClassIos`. Plugins with no class
  /// (facade/pure-Dart/FFI-only packages) remain SwiftPM target dependencies,
  /// but need no module import or registration call.
  @visibleForTesting
  static String registrantSource(
    List<IosPlugin> plugins, {
    bool verbose = false,
  }) {
    final imports = StringBuffer();
    final registrations = StringBuffer();
    var pluginCount = 0;
    for (final plugin in plugins) {
      final pluginClass = plugin.pluginClassIos;
      if (pluginClass == null) continue;
      pluginCount++;
      imports.writeln('import ${plugin.name}');
      if (verbose) {
        registrations.writeln('''
    NSLog("[xcross] registering plugin ${plugin.name} ($pluginClass)")
    if let registrar = registry.registrar(forPlugin: "$pluginClass") {
        $pluginClass.register(with: registrar)
        registered += 1
        NSLog("[xcross] registered plugin ${plugin.name} ($pluginClass)")
    } else {
        failures.append("${plugin.name} ($pluginClass): registrar unavailable")
        NSLog("[xcross] failed plugin ${plugin.name} ($pluginClass): registrar unavailable")
    }''');
      } else {
        registrations.writeln('''
    if let registrar = registry.registrar(forPlugin: "$pluginClass") {
        $pluginClass.register(with: registrar)
    }''');
      }
    }

    final diagnosticsStart = verbose
        ? '    var registered = 0\n'
              '    var failures: [String] = []\n'
        : '';
    final diagnosticsEnd = verbose
        ? '    NSLog("[xcross] plugin registration summary: '
              '$pluginCount attempted, \\(registered) registered, '
              '\\(failures.count) failed")\n'
              '    for failure in failures {\n'
              '        NSLog("[xcross] plugin registration failure: '
              '\\(failure)")\n'
              '    }\n'
        : '';

    return '''
//
// Generated file. Do not edit.
//
import Flutter
import UIKit
$imports
@_cdecl("${GeneratedPluginsConstants.registrantSymbol}")
public func xcrossRegisterGeneratedPlugins(_ registry: FlutterPluginRegistry) {
$diagnosticsStart$registrations$diagnosticsEnd}
''';
  }

  /// Writes [content] to [path] only when it differs.
  ///
  /// SwiftPM invalidates on timestamps, so rewriting identical generated
  /// files would recompile the whole plugin graph on every run.
  static Future<void> _writeStable(String path, String content) async {
    final file = File(path);
    if (file.existsSync() && await file.readAsString() == content) return;
    await _writeAtomic(path, utf8.encode(content));
  }

  static Future<void> _writeAtomic(String path, List<int> bytes) async {
    final temporary = File(
      '$path.xcross-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(path);
    } finally {
      if (temporary.existsSync()) await temporary.delete();
    }
  }

  static int _fileBytes(String path) {
    final file = File(path);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  static int _directoryBytes(String path) {
    final directory = Directory(_ioPath(path));
    if (!directory.existsSync()) return 0;
    var bytes = 0;
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) bytes += entity.lengthSync();
    }
    return bytes;
  }

  static String _ioPath(String path) {
    if (!Platform.isWindows) return path;
    final absolute = p.windows.normalize(p.windows.absolute(path));
    if (absolute.startsWith(r'\\?\')) return absolute;
    if (absolute.startsWith(r'\\')) {
      return '${r'\\?\UNC\'}${absolute.substring(2)}';
    }
    return '${r'\\?\'}$absolute';
  }

  static void _traceBinaryOperation({
    required String target,
    required String operation,
    required int elapsedMilliseconds,
    required int attempt,
    int archiveBytes = 0,
    int extractedBytes = 0,
  }) {
    Log.logTrace(
      'binary target=$target operation=$operation '
      'archive_bytes=$archiveBytes extracted_bytes=$extractedBytes '
      'elapsed_ms=$elapsedMilliseconds attempt=$attempt',
    );
  }

  /// Copies [source] to [destination], applying [transform] when it elects
  /// the file, and skipping the write when the destination already matches.
  ///
  /// The skip preserves destination timestamps, which SwiftPM invalidates
  /// on, so unchanged files stay warm in its incremental state. Files the
  /// transform declines are copied as raw bytes, so binaries are never
  /// decoded.
  static Future<bool> _syncFile(
    File source,
    String destination, {
    _SourceTransform? transform,
  }) async {
    List<int> bytes = await source.readAsBytes();
    final rewrite = transform?.call(source.path);
    if (rewrite != null) {
      bytes = utf8.encode(rewrite(utf8.decode(bytes)));
    }
    final existing = File(destination);
    if (existing.existsSync() &&
        _sameBytes(await existing.readAsBytes(), bytes)) {
      return false;
    }
    await existing.writeAsBytes(bytes);
    return true;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<void> _copyResolvedArtifactTree(
    String source,
    String destination, {
    String? artifactRoot,
    bool Function(String name)? includeTopLevel,
  }) async {
    final root = artifactRoot ?? p.normalize(p.absolute(source));
    await Directory(destination).create(recursive: true);
    await for (final entity in Directory(source).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (artifactRoot == null &&
          includeTopLevel != null &&
          !includeTopLevel(name)) {
        continue;
      }
      final target = p.join(destination, name);

      final resolved = p.normalize(
        p.absolute(
          entity is Link ? entity.resolveSymbolicLinksSync() : entity.path,
        ),
      );
      if (!p.equals(root, resolved) && !p.isWithin(root, resolved)) {
        throw FlutterBuildError(
          'SwiftPM binary artifact link escapes its artifact root',
          isSecurityFailure: true,
        );
      }
      if (Directory(resolved).existsSync()) {
        await _copyResolvedArtifactTree(
          resolved,
          target,
          artifactRoot: root,
          includeTopLevel: includeTopLevel,
        );
      } else if (File(resolved).existsSync()) {
        await File(resolved).copy(target);
      } else {
        throw FlutterBuildError(
          'SwiftPM binary artifact contains an unresolved link',
          isSecurityFailure: true,
        );
      }
    }
  }

  /// Mirrors [source] into [destination], resolving links to their

  /// targets, rewriting only differing files, and pruning entries the
  /// source no longer has. [preserve] names top-level entries the caller
  /// owns; [excludedSourcePath] guards against copying a destination that
  /// lives inside its own source.
  static Future<bool> _syncDirectory(
    String source,
    String destination, {
    Set<String> preserve = const {},
    String? excludedSourcePath,
    _SourceTransform? transform,
  }) async {
    final absoluteSource = p.normalize(p.absolute(source));
    final absoluteDestination = p.normalize(p.absolute(destination));
    if (p.equals(absoluteSource, absoluteDestination)) return false;
    var changed = !Directory(destination).existsSync();
    final excluded = excludedSourcePath == null
        ? (p.isWithin(absoluteSource, absoluteDestination)
              ? absoluteDestination
              : null)
        : p.normalize(p.absolute(excludedSourcePath));
    await Directory(destination).create(recursive: true);

    final expected = <String>{...preserve};
    await for (final entity in Directory(source).list(followLinks: false)) {
      if (excluded != null &&
          p.equals(p.normalize(p.absolute(entity.path)), excluded)) {
        continue;
      }
      final name = p.basename(entity.path);
      if (preserve.contains(name)) continue;
      expected.add(name);
      final destinationPath = p.join(destination, name);
      final resolved = entity is Link
          ? entity.resolveSymbolicLinksSync()
          : entity.path;
      if (Directory(resolved).existsSync()) {
        final existingType = FileSystemEntity.typeSync(
          destinationPath,
          followLinks: false,
        );
        await _deleteUnless(destinationPath, FileSystemEntityType.directory);
        changed =
            await _syncDirectory(
              resolved,
              destinationPath,
              excludedSourcePath: excluded,
              transform: transform,
            ) ||
            existingType != FileSystemEntityType.directory ||
            changed;
      } else {
        final existingType = FileSystemEntity.typeSync(
          destinationPath,
          followLinks: false,
        );
        await _deleteUnless(destinationPath, FileSystemEntityType.file);
        changed =
            await _syncFile(
              File(resolved),
              destinationPath,
              transform: transform,
            ) ||
            existingType != FileSystemEntityType.file ||
            changed;
      }
    }

    await for (final entity in Directory(
      destination,
    ).list(followLinks: false)) {
      if (!expected.contains(p.basename(entity.path))) {
        await _deleteEntity(entity.path);
        changed = true;
      }
    }
    return changed;
  }

  @visibleForTesting
  static List<String> windowsCopyArguments(String source, String destination) =>
      [
        source,
        destination,
        '/E',
        '/R:0',
        '/W:0',
        '/MT:8',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS',
        '/NP',
      ];

  static Future<void> _deleteUnless(
    String path,
    FileSystemEntityType keep,
  ) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound || type == keep) return;
    await _deleteEntity(path);
  }

  static Future<void> _deleteEntity(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }
  }

  /// Makes the staged Swift package appear directly beside FlutterFramework,
  /// so every plugin's conventional `../FlutterFramework` dependency resolves
  /// to the same package path. Directory junctions avoid Windows symlink
  /// privilege requirements.
  static Future<void> _createDirectoryAlias(String alias, String target) async {
    await _deleteEntity(alias);
    if (Platform.isWindows) {
      final result =
          await ProcessRunner.run(await ProcessRunner.locateTool('cmd.exe'), [
            '/c',
            'mklink',
            '/J',
            p.windows.normalize(alias),
            p.windows.normalize(p.absolute(target)),
          ]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Could not create plugin package junction: ${result.stderr}',
          alias,
        );
      }
      return;
    }

    await Link(alias).create(p.relative(target, from: p.dirname(alias)));
  }

  static String _jsonPath(String path) => path.replaceAll(r'\', '/');

  /// Forward-slash-safe absolute path for interpolation into a Swift string
  /// literal on every host.
  static String _swiftPath(String path) => _jsonPath(p.absolute(path));

  /// A pub package name with underscores replaced by hyphens — SwiftPM's own
  /// convention for a plugin's SPM library product name (used as the
  /// CFBundleIdentifier for dynamic products, which can't contain
  /// underscores). The `package:` argument stays underscored, matching the
  /// plugin's own unmodified `Package(name: ...)`.
  static String _hyphenate(String name) => name.replaceAll('_', '-');
}

/// Elects and rewrites file content during a directory sync: returns null
/// to copy [path] verbatim, or a rewriter for its decoded text.
typedef _SourceTransform =
    String Function(String content)? Function(String path);
