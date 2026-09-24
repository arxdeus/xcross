import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/build/internal/windows_swift_plan_repair.dart';
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

String _prependPathEntry(
  String directory,
  String? path, {
  required bool windows,
}) => path == null || path.isEmpty
    ? directory
    // `pathSeparator` joins a directory's components (`\\` on Windows), not
    // entries in PATH (`;` on Windows). A malformed PATH made the bundled
    // xcrun unreachable as soon as another entry followed it.
    : '$directory${windows ? ';' : ':'}$path';

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

    // v7 invalidated dylibs compiled with availability guards disabled; v8
    // invalidates staged sources compiled before State-wrapper recovery.
    add('xcross-swiftpm-build-v8-state-wrapper-recovery');
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
        jsonEncode(
          contentBuildIdentity(await resolveBuildToolchainIdentity(sdk!)),
        );
    add(resolvedToolchainIdentity);
    final resolvedSdkIdentity =
        sdkIdentity ??
        (sdk == null
            ? ''
            : jsonEncode(
                contentBuildIdentity(
                  await SdkInstall.sdkBuildIdentity(sdk.swiftSdkPath),
                ),
              ));
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
      add(
        p.relative(file.path, from: flutterXcframework).replaceAll(r'\', '/'),
      );
      add((await sha256.bind(file.openRead()).first).toString());
    }
    input.close();
    return result!.toString();
  }

  @visibleForTesting
  static Object? contentBuildIdentity(Object? value) => switch (value) {
    Map() => {
      for (final entry in value.entries)
        if (!value.containsKey('digest') ||
            (entry.key != 'modified' && entry.key != 'changed'))
          entry.key: contentBuildIdentity(entry.value),
    },
    List() => value.map(contentBuildIdentity).toList(),
    _ => value,
  };

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
    final baseArguments = swiftBuildArguments(
      pluginsDir: pluginsDir,
      scratchPath: scratchPath,
      swiftSdksPath: swiftSdksPath,
      iosSdk: sdk.iPhoneOSSdk(),
      flutterFrameworkSlice: flutterFrameworkSlice,
      objectiveCCompatibilityHeader: objectiveCCompatibilityHeader,
      toolsetPath: toolsetPath,
      linkerPath: windows ? null : linker,
      windows: windows,
      previewMacroStubPath: previewMacroStub,
    );
    if (windows) baseArguments.removeAt(0);
    await buildTranslatingSdkMismatch(
      () => ProcessRunner.runChecked(
        swiftBuild,
        [...baseArguments, '--print-manifest-job-graph'],
        environment: environment,
        label: 'swift build plan',
      ),
    );
    // Inspect the plan just emitted, not a directory from an earlier build.
    final targetBuildDir = resolveTargetBuildDir(scratchPath);
    await repairWindowsGeneratedBuildFiles(
      scratchPath,
      targetBuildDir,
      windows: windows,
    );
    final interopArguments = plannedSwiftInteropSearchPaths(targetBuildDir);
    // The first plan run could not carry [interopArguments], because the
    // paths it discovers are read out of the plan it produces. SwiftPM
    // records the resulting command lines in `debug.yaml` and llbuild
    // replays them verbatim, so without a second plan run every compile
    // would execute with the pre-interop arguments no matter what this
    // build passes. Re-planning rewrites the manifest with the search
    // paths applied.
    //
    // The rewrite only has to happen when the manifest does not already
    // carry the paths. Re-planning unconditionally costs a whole extra
    // `swift build` planning process (~13s on Windows for
    // examples/flutter_example) on every build including incremental ones,
    // to reproduce a manifest that is already byte-identical.
    if (interopArguments.isNotEmpty &&
        !manifestCarriesInteropSearchPaths(scratchPath, interopArguments)) {
      await buildTranslatingSdkMismatch(
        () => ProcessRunner.runChecked(
          swiftBuild,
          [...baseArguments, ...interopArguments, '--print-manifest-job-graph'],
          environment: environment,
          label: 'swift build plan (interop)',
        ),
      );
      await repairWindowsGeneratedBuildFiles(
        scratchPath,
        targetBuildDir,
        windows: windows,
      );
    }
    Future<void> runBuild([List<String> selection = const []]) async {
      final arguments = <String>[
        ...baseArguments,
        ...interopArguments,
        ...selection,
      ];

      Future<void> invoke() => ProcessRunner.runChecked(
        swiftBuild,
        arguments,
        environment: environment,
        captureAndEcho: windows && Log.isVerbose,
        label: 'swift build',
      );

      await repairWindowsGeneratedBuildFiles(
        scratchPath,
        targetBuildDir,
        windows: windows,
      );
      await buildWithSwiftUIStateRecovery(
        ownedRoots: [workspace.vendor, p.join(outputDir, 'Packages')],
        build: () async {
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
        },
      );
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
        skipInitialRecovery: true,
        repairConsumers: () => repairSwiftInteropConsumers(
          targetBuildDir: targetBuildDir,
          consumerProducts: interopConsumers,
        ),
        windows: windows,
      ),
    );
  }

  /// Retry once, and only when the exact compiler diagnostic changed owned
  /// staged sources. Unrelated failures and failed repairs keep their errors.
  @visibleForTesting
  static Future<void> buildWithSwiftUIStateRecovery({
    required Future<void> Function() build,
    required List<String> ownedRoots,
  }) async {
    try {
      await build();
    } on Object catch (error, stack) {
      bool changed;
      try {
        changed = await repairMissingSwiftUIStateMacro(
          error.toString(),
          ownedRoots: ownedRoots,
        );
      } on Object {
        Error.throwWithStackTrace(error, stack);
      }
      if (!changed) rethrow;
      await build();
    }
  }

  @visibleForTesting
  static Future<bool> repairMissingSwiftUIStateMacro(
    String diagnostics, {
    required List<String> ownedRoots,
  }) async {
    final diagnostic = RegExp(
      r"^(.+\.swift):\d+:\d+: error: external macro implementation type 'SwiftUIMacros\.StateMacro' could not be found for macro 'State\([^'\r\n]*\)'; plugin for module 'SwiftUIMacros' not found\s*$",
      multiLine: true,
    );
    final paths = diagnostic
        .allMatches(diagnostics)
        .map((match) => match[1]!)
        .toSet();
    if (paths.isEmpty) return false;
    final roots = <(String, String)>[
      for (final root in ownedRoots)
        if (Directory(root).existsSync())
          (
            p.normalize(p.absolute(root)),
            Directory(root).resolveSymbolicLinksSync(),
          ),
    ];
    var changed = false;
    for (final path in paths) {
      if (!p.isAbsolute(path)) continue;
      final file = File(p.normalize(path));
      if (!file.existsSync()) continue;
      final realPath = file.resolveSymbolicLinksSync();
      if (!roots.any(
        (root) =>
            p.isWithin(root.$1, file.path) && p.isWithin(root.$2, realPath),
      )) {
        continue;
      }
      final original = await file.readAsString();
      final repaired = restoreSwiftUIStatePropertyWrapper(original);
      if (repaired == original) continue;
      await _writeStable(file.path, repaired);
      changed = true;
    }
    return changed;
  }

  @visibleForTesting
  static Future<bool> repairWindowsGeneratedBuildFiles(
    String scratchPath,
    String targetBuildDir, {
    bool? windows,
  }) => WindowsSwiftPlanRepair.repairWindowsGeneratedBuildFiles(
    scratchPath,
    targetBuildDir,
    windows: windows,
  );

  @visibleForTesting
  static Future<bool> repairWindowsSwiftResponseFiles(
    String scratchPath, {
    bool? windows,
  }) => WindowsSwiftPlanRepair.repairWindowsSwiftResponseFiles(
    scratchPath,
    windows: windows,
  );

  @visibleForTesting
  static int windowsCommandLineLength(List<String> arguments) =>
      WindowsSwiftPlanRepair.windowsCommandLineLength(arguments);

  @visibleForTesting
  static String normalizeWindowsDirectoryCopyInputs(String description) =>
      WindowsSwiftPlanRepair.normalizeWindowsDirectoryCopyInputs(description);

  @visibleForTesting
  static Future<String> stageWindowsDirectoryCopyInputs(
    String description,
    String scratchPath, {
    bool? windows,
  }) => WindowsSwiftPlanRepair.stageWindowsDirectoryCopyInputs(
    description,
    scratchPath,
    windows: windows,
  );

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

  /// One `swift package resolve` attempt against [directory].
  ///
  /// SwiftPM resolves source-control dependencies by spawning git, so this
  /// needs the same non-interactive settings as our own clones: otherwise a
  /// moved or private dependency parks SwiftPM on an unanswerable credential
  /// prompt.
  ///
  /// Deliberately unbounded. A cold graph the size of firebase-ios-sdk is
  /// legitimately slow, and a wall-clock cap turned a slow build into a
  /// failed one. The non-interactive git settings in
  /// [swiftProcessEnvironment] are what keep a credential prompt from
  /// hanging forever, not a timeout.
  static Future<void> _resolveOnce(String swift, String directory) async {
    final result = await ProcessRunner.run(swift, [
      if (!Platform.isWindows) 'package',
      ...hostManifestArguments(),
      '--package-path',
      directory,
      'resolve',
    ], environment: swiftProcessEnvironment());
    if (result.exitCode != 0) {
      throw FlutterBuildError(
        'Cannot resolve SwiftPM dependencies in $directory:\n'
        '${resolveDiagnostics(result)}',
      );
    }
  }

  /// Both output streams of a failed resolve, in that order.
  ///
  /// SwiftPM reports fetch progress on stderr but writes the diagnostic that
  /// explains a failure to stdout, so reporting stderr alone produced CI logs
  /// that ended on a successful "Computed ..." line with no stated reason.
  /// The combined text is also what [isTransientNetworkFailure] matches on,
  /// so a reset that SwiftPM reports on stdout is still retried.
  @visibleForTesting
  static String resolveDiagnostics(CapturedProcess result) => [
    result.stdout.trim(),
    result.stderr.trim(),
  ].where((stream) => stream.isNotEmpty).join('\n');

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
    Future<void> resolveWithRetries() => retryingTransientNetworkFailure(
      resolve,
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
      resolve: resolveWithRetries,
      recoverBootstrap: recover,
      materialize: () => materializeCheckoutSymlinks(scratchPath),
      normalize: () => normalizeResolvedPackageManifests(scratchPath),
      recoverFinal: recover,
    );
  }

  /// Fragments that mark a dependency fetch as a transient network failure
  /// rather than a real, reproducible error.
  ///
  /// Resolving this plugin graph pulls from a dozen GitHub repositories, and
  /// a reset or refused connection on any one of them fails the whole build
  /// even though a retry moments later succeeds.
  @visibleForTesting
  static const transientNetworkFailureMarkers = <String>[
    'connection was reset',
    'could not connect to server',
    'failed to connect to',
    'recv failure',
    'send failure',
    'operation timed out',
    'connection timed out',
    'empty reply from server',
    'unexpected disconnect',
    'early eof',
    'rpc failed',
    'the remote end hung up',
    'temporary failure in name resolution',
    'could not resolve host',
    'ssl_read',
    'gnutls_handshake',
    'transfer closed',
    'http/2 stream',
    'couldn\u2019t fetch updates from remote repositories',
    "couldn't fetch updates from remote repositories",
  ];

  @visibleForTesting
  static bool isTransientNetworkFailure(Object error) {
    final text = error.toString().toLowerCase();
    // Our own timeout already waited the full budget; retrying it would
    // multiply the very stall the timeout exists to cut short.
    if (text.contains('and was killed')) return false;
    return transientNetworkFailureMarkers.any(text.contains);
  }

  /// Runs [action], retrying while it fails for an apparently transient
  /// network reason.
  ///
  /// Anything else propagates on the first attempt, so a genuine build error
  /// still fails fast instead of being retried three times.
  @visibleForTesting
  static Future<void> retryingTransientNetworkFailure(
    Future<void> Function() action, {
    required String label,
    int attempts = 3,
    Duration backoff = const Duration(seconds: 5),
    Future<void> Function(Duration)? delay,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action();
      } on Object catch (error) {
        if (attempt >= attempts || !isTransientNetworkFailure(error)) rethrow;
        final pause = backoff * attempt;
        Log.logTrace(
          '$label failed on a transient network error '
          '(attempt $attempt of $attempts), retrying in '
          '${pause.inSeconds}s: $error',
        );
        await (delay ?? Future<void>.delayed)(pause);
      }
    }
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
          if (rewritten != original) {
            await write(manifestFile.path, utf8.encode(rewritten));
          }
          // SwiftPM invalidates on timestamps, and a manifest's timestamp
          // invalidates every target in its package. Vendoring restores the
          // upstream manifest with `git reset --hard` before each build, so
          // this rewrite lands on a file git has just re-stamped: 12
          // manifests per run, each with the same bytes as the run before,
          // and that alone made the whole Firebase graph recompile on every
          // incremental build.
          //
          // Neither the pre-write timestamp nor "skip when unchanged" can
          // fix that, because the reset moves the timestamp and reverts the
          // content before this code runs. Deriving the timestamp from the
          // bytes does: identical patched manifests always carry an
          // identical timestamp, and a genuinely new patch still gets a new
          // one.
          await _stampByContent(manifestFile.path, rewritten);
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
    } on Object catch (error) {
      // A resolve we killed for exceeding its own timeout is not a missing
      // binary artifact, and re-running it just waits out the same stall
      // again. Two such rounds are what kept the Windows job alive to the
      // 90-minute job limit even after the timeout started firing.
      if (isResolveTimeout(error)) rethrow;
      if (!await recover()) rethrow;
      await resolve();
    }
  }

  /// Whether [error] is a resolve this tool killed for exceeding its timeout.
  ///
  /// Distinguishes our own deliberate kill from a failure of the work, so
  /// recovery and retry paths can decline to run the same stall again.
  @visibleForTesting
  static bool isResolveTimeout(Object error) =>
      error.toString().contains('and was killed') ||
      error.toString().contains('took longer than');

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
    PrepareSwiftPmBinaryArtifact? prepare,
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
            // SwiftPM deletes the archive once it has extracted it, so the
            // usual case here is a bare extracted tree. That tree is not
            // checksum-verified and can be partial: on the Windows CI runner
            // SwiftPM hit I/O error 514 mid-resolve and left
            // FirebaseFirestoreInternal.framework without its Headers, which
            // the store then served as complete to every later build. The
            // manifest's URL and checksum rebuild the artifact from a verified
            // archive, so try that before trusting the tree.
            if (verified.isEmpty) {
              try {
                verified.add(
                  (await (prepare ?? preparer.prepare)(candidate.target)).entry,
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
                final store = Directory(binaryArtifactStore);
                await store.create(recursive: true);
                final staging = await store.createTemp('.extracted-');
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
    bool skipInitialRecovery = false,
    bool? windows,
  }) async {
    final repair = repairConsumers ?? () async {};

    Future<bool> recoverMissingTargets({Set<String>? candidates}) async {
      final targets = missingSwiftInteropTargets(
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
    final planned = plannedSwiftInteropTargets(
      targetBuildDir,
      candidates: interopTargetCandidates,
      windows: windows,
    );
    final prebuild = (windows ?? Platform.isWindows)
        ? orderedWindowsSwiftInteropTargets(targetBuildDir, planned)
        : planned;
    for (final target in prebuild) {
      await buildTarget(target);
    }
    await repair();
    if (!skipInitialRecovery && await recoverMissingTargets()) {
      await build();
      return;
    }

    final before = swiftInteropSearchPaths(targetBuildDir).toSet();
    final missingBefore = missingSwiftInteropTargets(
      targetBuildDir,
      candidates: interopTargetCandidates,
    ).toSet();
    try {
      await build();
    } on Object catch (error, stack) {
      final missingHeader = _missingSwiftHeaderDiagnostic.hasMatch(
        error.toString(),
      );
      final newlyExposed = missingSwiftInteropTargets(
        targetBuildDir,
        candidates: interopTargetCandidates,
      ).toSet().difference(missingBefore);
      if (!missingHeader && newlyExposed.isEmpty) rethrow;

      // Step 1: prebuild the targets whose header is still missing, then
      // retry. A failure here reports the original build error.
      final candidates = _reachableInteropCandidates(
        targetBuildDir,
        interopTargetCandidates,
      );
      final recovered = await _reportingOriginalFailure(error, stack, () async {
        if (!await recoverMissingTargets(candidates: candidates)) {
          return false;
        }
        await build();
        return true;
      });
      if (recovered) return;

      // Step 2 (Windows only): the build emitted new interop search paths,
      // so repair their consumers once and retry.
      final emitted = swiftInteropSearchPaths(
        targetBuildDir,
      ).toSet().difference(before);
      if (!(windows ?? Platform.isWindows) || emitted.isEmpty) {
        rethrow;
      }
      await _reportingOriginalFailure(error, stack, repair);
      await build();
    }
  }

  /// A compiler diagnostic naming a generated `<Target>-Swift.h` header that
  /// could not be found.
  static final RegExp _missingSwiftHeaderDiagnostic = RegExp(
    r'[A-Za-z_0-9-]+-Swift\.h[^\n]*(?:file not found|not found|No such file)',
    caseSensitive: false,
  );

  /// [interopTargetCandidates] plus every target the aggregate build plan
  /// reaches. Internal targets may be absent from public products, but must
  /// still be reachable from the generated aggregate build plan.
  static Set<String> _reachableInteropCandidates(
    String targetBuildDir,
    Set<String> interopTargetCandidates,
  ) {
    final reachable = plannedTargetClosure(targetBuildDir, _pluginsProductName);
    return {...interopTargetCandidates, if (reachable != null) ...reachable};
  }

  /// Runs a recovery [step] for a build that failed with [error], rethrowing
  /// that original failure with its [stack] if the step itself fails, since
  /// the original diagnostic is the one a user can act on.
  static Future<T> _reportingOriginalFailure<T>(
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

  @visibleForTesting
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
    final reachable = plannedTargetClosure(targetBuildDir, _pluginsProductName);
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

  /// Environment that makes Git — and anything spawning it, including
  /// SwiftPM's own dependency resolution — fail instead of waiting on a
  /// human.
  ///
  /// Nothing is attached to this build's stdin: our runners pipe it and
  /// SwiftPM pipes its children too. So when a vendored dependency's
  /// repository has moved, gone private, or started rate-limiting, Git's
  /// default answer — prompt for credentials — is a prompt no one can see
  /// or answer, and the child waits forever. On Windows, Git Credential
  /// Manager escalates that to an invisible GUI dialog. That is how a CI
  /// job sits for hours inside `Building Flutter plugins` printing nothing.
  ///
  /// * `GIT_TERMINAL_PROMPT=0` refuses username/password prompts on a tty.
  /// * Empty `GIT_ASKPASS`/`SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=never`
  ///   disables the graphical fallbacks Git uses when there is no tty.
  /// * `GCM_INTERACTIVE=never` and `GCM_PROVIDER=none` keep Git Credential
  ///   Manager from opening a window of its own.
  /// * `GIT_SSH_COMMAND` with `BatchMode=yes` fails an SSH remote outright
  ///   instead of asking for a passphrase or host-key confirmation.
  ///
  /// Each one turns a silent hang into an ordinary clone failure whose
  /// message names the repository that could not be read.
  @visibleForTesting
  static const Map<String, String> nonInteractiveGitEnvironment = {
    'GIT_TERMINAL_PROMPT': '0',
    'GIT_ASKPASS': '',
    'SSH_ASKPASS': '',
    'SSH_ASKPASS_REQUIRE': 'never',
    'GCM_INTERACTIVE': 'never',
    'GCM_PROVIDER': 'none',
    'GIT_SSH_COMMAND':
        'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new',
  };

  /// Git settings applied through `GIT_CONFIG_*`, in order.
  ///
  /// Resetting `credential.helper` closes the last door: a helper
  /// configured system-wide — Git Credential Manager on the Windows
  /// runners, `osxkeychain` on a developer's Mac — is consulted before any
  /// prompt setting applies, and it can block on its own UI. Clearing the
  /// list leaves Git with nobody to ask.
  ///
  /// The value is `""`, not the empty string: Git parses `GIT_CONFIG_VALUE_*`
  /// the way it parses a config file, and rejects a genuinely empty one with
  /// "missing config value ... fatal: unable to parse command-line config",
  /// which would fail every git command this build runs rather than only the
  /// ones that need credentials. Two quotes are the config-file spelling of
  /// an empty value, and an empty `credential.helper` is what resets the
  /// list.
  ///
  /// `core.symlinks=false` keeps Windows checkouts on placeholder files
  /// that [materializeGitCheckoutSymlinks] converts afterwards. Our own
  /// clones override it per command with `-c core.symlinks=true` where the
  /// host can create real symlinks; a command-line `-c` outranks these.
  static List<({String key, String value})> _gitConfigEntries({
    required bool windows,
  }) => [
    (key: 'credential.helper', value: '""'),
    // Git 2.36+ refuses a helper prompt outright; older Git ignores it and
    // relies on the reset above.
    (key: 'credential.interactive', value: 'false'),
    // Abort a transfer that delivers less than 1 KiB/s for 60s rather than
    // holding the connection open indefinitely. GitHub occasionally resets or
    // silently drops these fetches, and SwiftPM inherits the stall: the build
    // then sits with no output until the CI job is killed. With this, git
    // fails fast and the error is visible and retryable.
    (key: 'http.lowSpeedLimit', value: '1024'),
    (key: 'http.lowSpeedTime', value: '60'),
    if (windows) (key: 'core.symlinks', value: 'false'),
  ];

  /// Whether vendored packages build their `EXPERIMENTAL_SPM_BUILDS`
  /// source-fallback lane, which [swiftProcessEnvironment] enables only on
  /// Windows. Tests may force either lane.
  @visibleForTesting
  static bool? sourceFallbackOverride;

  static bool get _sourceFallbackActive =>
      sourceFallbackOverride ?? Platform.isWindows;

  /// Process-local settings for SwiftPM dependency checkout: the
  /// non-interactive Git settings every host needs, plus Windows checkout
  /// compatibility settings for symlinks and source-build manifests.
  static Map<String, String>? swiftProcessEnvironment({
    bool? windows,
    String? executable,
    Map<String, String>? environment,
  }) {
    final onWindows = windows ?? Platform.isWindows;
    final config = _gitConfigEntries(windows: onWindows);
    final bundledTools = p.dirname(executable ?? Platform.resolvedExecutable);
    final bundledXcrun = File(
      p.join(bundledTools, onWindows ? 'xcrun.exe' : 'xcrun'),
    );
    return {
      ...nonInteractiveGitEnvironment,
      'GIT_CONFIG_COUNT': '${config.length}',
      for (final (index, entry) in config.indexed) ...{
        'GIT_CONFIG_KEY_$index': entry.key,
        'GIT_CONFIG_VALUE_$index': entry.value,
      },
      if (onWindows) 'EXPERIMENTAL_SPM_BUILDS': '1',
      // SwiftPM build tools call `xcrun` through PATH. Prefer the xcrun
      // bundled beside this executable over a separately installed version,
      // which may not understand the iPhoneOS platform probes.
      if (onWindows && bundledXcrun.existsSync())
        'PATH': _prependPathEntry(
          bundledTools,
          ProcessRunner.environmentValue(
            environment ?? ProcessRunner.effectiveEnvironment,
            'PATH',
          ),
          windows: onWindows,
        ),
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
    ...hostManifestArguments(),
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

  /// Supply the Windows C runtime to host manifests, including remote manifests
  /// SwiftPM evaluates before creating a checkout. Swift 6 replaced MSVCRT with
  /// CRT, so old conditional imports otherwise leave C APIs such as getenv
  /// unavailable. These flags affect host manifests, never iOS target sources.
  @visibleForTesting
  static List<String> hostManifestArguments({bool? windows}) =>
      (windows ?? Platform.isWindows)
      ? const [
          '-Xmanifest',
          '-Xfrontend',
          '-Xmanifest',
          '-import-module',
          '-Xmanifest',
          '-Xfrontend',
          '-Xmanifest',
          'CRT',
        ]
      : const [];

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

  /// The directory SwiftPM writes build artifacts (`description.json`, the
  /// per-target `.build` folders) into, inside [scratchPath].
  ///
  /// Swift 6.4's swiftbuild engine drops the per-triple level and writes
  /// to `<scratch>/out/debug` instead of `<scratch>/<triple>/debug`. This
  /// build pins the native engine, which keeps the per-triple layout, so
  /// that is preferred: a stale `out/debug` left behind by a default-engine
  /// run must not win. When neither exists yet the per-triple path is
  /// returned so the missing-description diagnostic names a real location.
  @visibleForTesting
  static String resolveTargetBuildDir(
    String scratchPath, {
    String triple = 'arm64-apple-ios',
    String configuration = 'debug',
  }) {
    final candidates = [
      p.join(scratchPath, triple, configuration),
      p.join(scratchPath, 'out', configuration),
    ];
    for (final candidate in candidates) {
      if (File(p.join(candidate, 'description.json')).existsSync()) {
        return candidate;
      }
    }
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }
    return p.join(scratchPath, triple, configuration);
  }

  @visibleForTesting
  static List<String> plannedSwiftInteropSearchPaths(String targetBuildDir) {
    final description = File(p.join(targetBuildDir, 'description.json'));
    try {
      final decoded = jsonDecode(description.readAsStringSync());
      if (decoded is! Map<String, dynamic> ||
          decoded['swiftCommands'] is! Map<String, dynamic>) {
        throw const FormatException('Missing Swift command descriptions');
      }
      final includes = <String>{};
      for (final command
          in (decoded['swiftCommands'] as Map<String, dynamic>).values) {
        if (command is! Map<String, dynamic> ||
            command['otherArguments'] is! List ||
            !(command['otherArguments'] as List).every(
              (argument) => argument is String,
            )) {
          throw const FormatException('Invalid Swift command arguments');
        }
        final arguments = (command['otherArguments'] as List).cast<String>();
        for (var index = 0; index < arguments.length; index++) {
          if (arguments[index] != '-emit-objc-header-path') continue;
          if (++index >= arguments.length) {
            throw const FormatException('Missing generated header path');
          }
          final header = p.normalize(arguments[index]);
          if (!p.isAbsolute(header) ||
              !p.isWithin(p.normalize(p.absolute(targetBuildDir)), header) ||
              !header.endsWith('-Swift.h')) {
            throw const FormatException('Invalid generated header path');
          }
          includes.add(p.dirname(header));
        }
      }
      final sorted = includes.toList()..sort();
      return [
        for (final include in sorted) ...['-Xcc', '-I', '-Xcc', include],
      ];
    } on Object catch (error) {
      throw FlutterBuildError(
        'Cannot read planned Swift interop headers from '
        '${description.path}: $error',
      );
    }
  }

  /// Targets the build plan says will emit a `-Swift.h` that is not on disk.
  ///
  /// Unlike [missingSwiftInteropTargets], which can only see a module map
  /// SwiftPM has already written, this reads the plan, so it knows the full
  /// set before the first compile. That difference is what makes the prepass
  /// deterministic: on a cold build no module map exists yet, so scanning the
  /// build directory finds nothing to prebuild and the race is entered
  /// anyway.
  ///
  /// Names are returned in plan order so the prepass is reproducible.
  @visibleForTesting
  static List<String> plannedSwiftInteropTargets(
    String targetBuildDir, {
    required Set<String> candidates,
    bool? windows,
  }) {
    // The plan is an optimisation for the prepass, not a requirement: without
    // it the existing after-the-fact recovery still runs. A build directory
    // with no readable plan therefore means "nothing to prebuild", not a
    // build failure.
    final List<String> planned;
    try {
      planned = plannedSwiftInteropSearchPaths(targetBuildDir);
    } on Object {
      return const [];
    }
    // Only a target the aggregate actually reaches can be compiled by the
    // aggregate build, so only such a target can lose the header race the
    // prepass exists to prevent. The plan lists every target in the resolved
    // dependency graph, including the ones no product here depends on:
    // measured on examples/flutter_example that is 18 of 37, and each one
    // costs a whole `swift build` process (~4-13s on Windows) that can never
    // emit its header, because nothing schedules the target that would.
    // Prebuilding them was therefore pure latency, paid on every build,
    // forever: 13 unreachable targets re-prebuilt on each incremental run.
    final reachable = plannedTargetClosure(targetBuildDir, _pluginsProductName);
    final targets = <String>{};
    for (final argument in planned) {
      final directory = p.basename(argument);
      if (directory != 'include') continue;
      final owner = p.basename(p.dirname(argument));
      if (!owner.endsWith('.build')) continue;
      final target = owner.substring(0, owner.length - '.build'.length);
      // A generated aggregate may reach an internal Swift target through a
      // product even though that target is not itself a public product.
      // Windows must include reachable internal Swift header targets,
      // including when older plans carry no dependency map. Preserve the
      // public-product candidate filter on POSIX hosts for every plan.
      if (!(windows ?? Platform.isWindows) && !candidates.contains(target)) {
        continue;
      }
      if (reachable != null && !reachable.contains(target)) continue;
      if (File(p.join(argument, '$target-Swift.h')).existsSync()) continue;
      targets.add(target);
    }
    final sorted = targets.toList()..sort();
    return sorted;
  }

  /// The aggregate target is the build that follows this prepass, never a
  /// prebuild target. Build reachable Swift dependencies before consumers
  /// even when alphabetical names would schedule them in reverse.
  @visibleForTesting
  static List<String> orderedWindowsSwiftInteropTargets(
    String targetBuildDir,
    List<String> planned,
  ) {
    final eligible = planned.toSet()..remove(_pluginsProductName);
    final description = File(p.join(targetBuildDir, 'description.json'));
    Map<String, dynamic>? dependencies;
    try {
      final decoded = jsonDecode(description.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        dependencies = decoded['targetDependencyMap'] as Map<String, dynamic>?;
      }
    } on Object {
      // Preserve the prepass for older SwiftPM descriptions with no map.
    }
    final ordered = <String>[];
    final visited = <String>{};
    final visiting = <String>{};

    void visit(String target) {
      if (!eligible.contains(target) || visited.contains(target)) return;
      if (!visiting.add(target)) {
        throw FlutterBuildError(
          'SwiftPM interop target dependency cycle at $target',
        );
      }
      final children = dependencies?[target];
      if (children is List) {
        for (final dependency in children.whereType<String>()) {
          visit(dependency);
        }
      }
      visiting.remove(target);
      visited.add(target);
      ordered.add(target);
    }

    for (final target in planned) {
      visit(target);
    }
    return ordered;
  }

  /// [root] and every target reachable from it in the plan's dependency map.
  ///
  /// Returns null when the plan carries no usable dependency map, so callers
  /// can tell "nothing is reachable" apart from "reachability is unknown".
  @visibleForTesting
  static Set<String>? plannedTargetClosure(String targetBuildDir, String root) {
    final description = File(p.join(targetBuildDir, 'description.json'));
    final Map<String, List<String>> edges;
    try {
      final decoded = jsonDecode(description.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      final map = decoded['targetDependencyMap'];
      if (map is! Map<String, dynamic>) return null;
      edges = {
        for (final entry in map.entries)
          if (entry.value case final List<dynamic> dependencies)
            entry.key: [
              for (final dependency in dependencies)
                if (dependency is String) dependency,
            ],
      };
    } on Object {
      return null;
    }
    if (edges.isEmpty) return null;
    final seen = <String>{root};
    final stack = <String>[root];
    while (stack.isNotEmpty) {
      for (final next in edges[stack.removeLast()] ?? const <String>[]) {
        if (seen.add(next)) stack.add(next);
      }
    }
    return seen;
  }

  /// Whether the llbuild manifest already applies every interop search path.
  ///
  /// llbuild replays the command lines recorded in `debug.yaml` verbatim, so
  /// a manifest that already names each path produces exactly the build a
  /// re-plan would produce. The manifest is JSON-quoted, so the separators
  /// of a Windows path appear escaped.
  @visibleForTesting
  static bool manifestCarriesInteropSearchPaths(
    String scratchPath,
    List<String> interopArguments,
  ) {
    final manifest = File(p.join(scratchPath, 'debug.yaml'));
    final String text;
    try {
      text = manifest.readAsStringSync();
    } on Object {
      return false;
    }
    if (text.isEmpty) return false;
    // On Windows, long compiler command lines move into response files, so
    // a path may be recorded there instead of in the manifest itself.
    final responseArguments =
        WindowsSwiftPlanRepair.referencedResponseArguments(text, scratchPath);
    if (responseArguments == null) return false;
    bool recorded(String path) =>
        text.contains(jsonEncode(path)) ||
        responseArguments.contains(
          WindowsSwiftPlanRepair.quoteWindowsArgument(path),
        ) ||
        responseArguments.contains(
          WindowsSwiftPlanRepair.quoteGnuArgument(path),
        );
    var checked = 0;
    // [plannedSwiftInteropSearchPaths] emits each include as the quadruple
    // `-Xcc -I -Xcc <path>`, so the path follows the `-I` across the `-Xcc`
    // that forwards it to Clang.
    for (var index = 0; index + 2 < interopArguments.length; index++) {
      if (interopArguments[index] != '-I') continue;
      if (interopArguments[index + 1] != '-Xcc') continue;
      checked++;
      if (!recorded(interopArguments[index + 2])) return false;
    }
    return checked > 0;
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
    // Swift 6.4 made `swiftbuild` the default build system. It only knows
    // the Apple platforms a host Xcode registers, so on a cross host it
    // rejects this build outright with 'unable to find platform for
    // iphoneos', and it drops the per-triple level from the scratch layout
    // this code reads its build description from. The native engine is what
    // supports the cross build, so ask for it rather than inherit the default.
    '--build-system',
    'native',
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
      ...hostManifestArguments(windows: true),
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
    // Preserve Swift #available runtime guards. Disabling availability checks
    // also removes these guards and can call newer weak-linked APIs on older
    // operating systems where those weak-linked APIs do not exist.
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
          await _stagePluginPackage(
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
      final bootstrap = windows
          ? await bootstrapWindowsPinnedDependencyResolve(
              prestaged,
              resolvedVendorDir,
              clonePackage: clonePackage,
            )
          : (pins: <String, String>{}, originals: <String, String>{});
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
              : _evaluatedDependencyRefs(
                  directory,
                  ProcessRunner.locateTool,
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
          await _writeStable(entry.key, entry.value);
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
        evaluateDependencyRefs: pluginRefEvaluator,
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

  /// SwiftPM evaluates remote manifests before checkout normalization can fix
  /// host-incompatible declarations. Prestage deterministically pinned Git
  /// dependencies through normalized local checkouts for the resolve pass,
  /// then restore the original plugin manifests for normal vendoring. Leave
  /// version ranges to SwiftPM's solver rather than choosing a version here.
  @visibleForTesting
  static Future<({Map<String, String> pins, Map<String, String> originals})>
  bootstrapWindowsPinnedDependencyResolve(
    Iterable<String> packageDirectories,
    String vendorDir, {
    bool? windows,
    Future<void> Function(
      String git,
      String url,
      String ref,
      String destination,
    )?
    clonePackage,
  }) async {
    if (!(windows ?? Platform.isWindows)) {
      return (pins: <String, String>{}, originals: <String, String>{});
    }
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
      for (final dependency in parseUrlPackageDeps(original)) {
        final identity = _canonicalGitUrl(dependency.url);
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
            .addAll(_consumedProducts(original, dependency.identity));
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
      final destination = p.join(vendorDir, vendorPackageDirName(url, ref));
      git ??= await ProcessRunner.locateTool('git');
      await (clonePackage ?? _cloneGitPackage)(git, url, ref, destination);
      await _normalizeVendoredPackageManifests(
        destination,
        consumedProducts: products[identity]!,
      );
      replacements[identity] = destination;
    }
    for (final entry in manifests.entries) {
      var rewritten = entry.value;
      for (final dependency in parseUrlPackageDeps(entry.value)) {
        final identity = _canonicalGitUrl(dependency.url);
        if (!replacements.containsKey(identity)) continue;
        rewritten = rewritten.replaceAll(
          dependency.match,
          '.package(name: "${dependency.identity}", '
          'path: "${_swiftPath(replacements[identity]!)}")',
        );
      }
      if (rewritten != entry.value) {
        originals[entry.key] = entry.value;
        rewrites[entry.key] = rewritten;
      }
    }
    try {
      for (final entry in rewrites.entries) {
        await _writeStable(entry.key, entry.value);
      }
    } on Object {
      for (final entry in originals.entries) {
        await _writeStable(entry.key, entry.value);
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
  @visibleForTesting
  static Future<Map<String, String>?> resolveUnifiedDependencyRefs({
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
      for (final dep in parseUrlPackageDeps(await manifest.readAsString())) {
        dependencies.putIfAbsent(_canonicalGitUrl(dep.url), () => dep);
      }
    }
    if (dependencies.isEmpty) return null;

    await Directory(resolveRoot).create(recursive: true);
    final hidden = <String, String>{};
    var refs = <String, String>{};
    for (var round = 0; round < maxRounds; round++) {
      await _writeStable(
        p.join(resolveRoot, 'Package.swift'),
        _resolveManifest(packageDirectories, hidden.values),
      );
      refs = await evaluate(resolveRoot, dependencies.values.toList());
      final discovered = await _hiddenDependencyCalls(
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

  static String _resolveManifest(
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
      buffer.writeln('        .package(path: "${_swiftPath(directory)}"),');
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
  static Future<Map<String, String>> _hiddenDependencyCalls(
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
      for (final url in refs.keys) packageIdentityFromUrl(url).toLowerCase(),
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
      final manifest = normalizeHostManifest(await manifestFile.readAsString());
      final deps = parseUrlPackageDeps(manifest);
      final unpinned = deps.where(
        (dep) => !refs.containsKey(_canonicalGitUrl(dep.url)),
      );
      if (unpinned.isEmpty ||
          unpinned.every(
            (dep) => dependencies.containsKey(_canonicalGitUrl(dep.url)),
          )) {
        continue;
      }
      for (final dep in deps) {
        final identity = packageIdentityFromUrl(dep.url).toLowerCase();
        if (declared.contains(identity)) continue;
        final call = _standaloneDependencyCall(dep, manifest);
        if (call == null) continue;
        // One entry per identity: firebase declares each helper dep twice
        // (a CI-only `branch:` variant and the released range) and SwiftPM
        // rejects duplicate identities in a manifest. Prefer the range.
        final existing = result[identity];
        if (existing == null || _isBranchRequirement(existing)) {
          result[identity] = call;
        }
        dependencies.putIfAbsent(_canonicalGitUrl(dep.url), () => dep);
      }
    }
    return result;
  }

  static bool _isBranchRequirement(String call) =>
      RegExp(r'\bbranch\s*:').hasMatch(call);

  /// Identifiers a `.package(url:)` requirement may use as values without a
  /// declaration; argument labels (`from:`, `branch:`) are skipped separately.
  static const _dependencyCallIdentifiers = {'Version'};

  /// `.package(url: "<literal>", <requirement>)` for [dep] that compiles on
  /// its own, or null when the requirement references manifest state that
  /// cannot be carried over (e.g. firebase's `packageInfo.range` tuples).
  /// String constants the requirement uses are inlined as literals.
  static String? _standaloneDependencyCall(
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
    final constants = _manifestStringConstants(manifest);
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
    // The manifest is regenerated from the plugin's own each build and can
    // legitimately differ between the staging write and a later pass, so
    // "write only when changed" cannot keep its timestamp fixed on its own.
    // SwiftPM invalidates a package's whole target set on its manifest
    // timestamp, so stamp by content: identical output keeps the timestamp
    // SwiftPM already compiled against.
    await _stampByContent(p.join(staged, 'Package.swift'), manifest);
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
      registrantSource(
        plugins,
        verbose: verbose,
        stagedPackageDirs: pluginPackageDirs,
      ),
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
      r'\b(?:let|var)\s+(?<name>[A-Za-z_]\w*)\s*(?::\s*[\w.<>]+)?\s*=\s*"(?<value>[^"\r\n]*)"',
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

  /// Swift tools version declared by [manifest], or `null` when absent.
  ///
  /// `.package(name:path:)` only exists from PackageDescription 5.2, so a
  /// vendored manifest older than that (SDWebImageWebPCoder pins 5.0) must
  /// get a plain `.package(path:)`. Pre-5.2 SwiftPM derives the dependency
  /// name from the dependency's own `Package(name:)`, so target references
  /// keep resolving without an explicit `name:`.
  @visibleForTesting
  static ({int major, int minor})? manifestToolsVersion(String manifest) {
    final match = RegExp(
      r'^//\s*swift-tools-version\s*:?\s*(\d+)(?:\.(\d+))?',
      multiLine: true,
    ).firstMatch(manifest);
    if (match == null) return null;
    return (
      major: int.parse(match.group(1)!),
      minor: int.tryParse(match.group(2) ?? '0') ?? 0,
    );
  }

  static bool _supportsNamedPathDeps(String manifest) {
    final version = manifestToolsVersion(manifest);
    if (version == null) return true;
    return version.major > 5 || (version.major == 5 && version.minor >= 2);
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

  /// Manifest files tracked anywhere in a SwiftPM checkout, without walking
  /// its working tree. Git for Windows handles its index with
  /// `core.longpaths=true`, so irrelevant deep assets cannot make discovery
  /// fail with MAX_PATH.
  @visibleForTesting
  static Future<List<File>> trackedPackageManifestFiles(
    String packageDirectory, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final result = await (runProcess ?? ProcessRunner.run)('git', [
      '-c',
      'core.longpaths=true',
      '-C',
      packageDirectory,
      'ls-files',
      '-z',
      '--',
      'Package.swift',
      'Package@*.swift',
      ':(glob)**/Package.swift',
      ':(glob)**/Package@*.swift',
    ]);
    if (result.exitCode != 0) {
      throw FlutterBuildError(
        'Could not inspect SwiftPM checkout $packageDirectory: '
        '${result.stderr.trim()}',
      );
    }
    final paths =
        result.stdout
            .split('\u0000')
            .where((path) => path.isNotEmpty)
            .map((path) => File(p.join(packageDirectory, p.fromUri(path))))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return paths;
  }

  static List<File> _rootPackageManifestFiles(String packageDirectory) {
    final root = Directory(packageDirectory);
    if (!root.existsSync()) return const [];
    final files = root.listSync(followLinks: false).whereType<File>().where((
      file,
    ) {
      final name = p.basename(file.path);
      return name == 'Package.swift' ||
          (name.startsWith('Package@') && name.endsWith('.swift'));
    }).toList()..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

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
      if (!Directory(entry.key).existsSync()) continue;
      final manifests = entry.value == null
          ? _rootPackageManifestFiles(entry.key)
          : await trackedPackageManifestFiles(entry.key);
      for (final entity in manifests) {
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

  @visibleForTesting
  static String? dependencyResolverScratchPath({
    required String packageDirectory,
    required String? scratchPath,
    required bool usesDefaultResolver,
  }) => usesDefaultResolver ? p.join(packageDirectory, '.build') : scratchPath;

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
        (directory) => retryingTransientNetworkFailure(
          () => _resolveOnce(swift, directory),
          label: 'swift package resolve',
        );
    // `swift package --package-path <directory> resolve` uses
    // `<directory>/.build`; it does not share the final build's explicit
    // scratch path. Recovery must inspect the checkouts and artifacts from
    // this resolver invocation, not `workspace.scratch`.
    final resolverScratchPath = dependencyResolverScratchPath(
      packageDirectory: packageDirectory,
      scratchPath: scratchPath,
      usesDefaultResolver: resolve == null,
    );
    final canRecover =
        recover != null ||
        (Platform.isWindows &&
            resolverScratchPath != null &&
            binaryArtifactStore != null &&
            binaryArtifactFallback != null);
    final scannedProvenance = recover == null && canRecover
        ? await _binaryArtifactProvenance(
            packageDirectory,
            resolverScratchPath!,
            dependencies,
          )
        : null;
    return evaluateDependencyRefsWithRecovery(
      packageDirectory,
      resolve: runResolve,
      recover:
          recover ??
          (_, state) async {
            if (!canRecover) return false;
            // The unified Resolve root fetches URL dependencies before they
            // are vendored. A malformed host manifest can fail the first
            // resolve before binary artifacts are considered. Repair
            // those fetched checkouts and retry with the existing recovery.
            final normalized = await normalizeResolvedPackageManifests(
              resolverScratchPath!,
            );
            final recoveredArchive = await recoverBootstrapBinaryArtifacts(
              scratchPath: resolverScratchPath,
              binaryArtifactStore: binaryArtifactStore!,
              provenance: scannedProvenance!,
              attemptState: state,
              swiftPmArtifactJunctionCapability:
                  swiftPmArtifactJunctionCapability,
            );
            final recoveredExtraction = await stageExtractedBinaryArtifacts(
              scratchPath: resolverScratchPath,
              vendorDir: p.join(resolverScratchPath, '.xcross-vendor'),
              binaryArtifactStore: binaryArtifactStore,
              binaryArtifactFallback: binaryArtifactFallback,
              attemptState: state,
              windows: true,
            );
            return normalized || recoveredArchive || recoveredExtraction;
          },
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
      final evaluationKey = await _dependencyEvaluationKey(manifest, directory);
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

    final clone = clonePackage ?? _cloneGitPackage;

    Future<void> cloneAndMaterialize(
      String url,
      String ref,
      String destination,
    ) async {
      await clone(git, url, ref, destination);
      if (Platform.isWindows && clonePackage == null) {
        await materializeGitCheckoutSymlinks(
          destination,
          git: git,
          stampDir: p.join(vendorDir, '.xcross-symlinks'),
        );
      }
    }

    Future<void> checkout(String url, String ref, String destination) async {
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

    return _vendorUrlDeps(
      manifest,
      vendorDir: vendorDir,
      evaluatedRefs: evaluatedRefs,
      checkout: checkout,
      vendored: <String>{},
      requireResolvedRefs: true,
      evaluateNested: evaluateCached,
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
    Future<Map<String, String>> Function(
      String manifest,
      String packageDirectory,
      List<SwiftPmPackageDependency> dependencies,
    )?
    evaluateNested,
    Map<String, List<String>>? fallbackSwiftModules,
    Map<String, Map<String, List<String>>>? normalizationCache,
  }) async {
    final deps = parseUrlPackageDeps(manifest);
    if (deps.isEmpty) return manifest;

    var result = manifest;
    final namedPathDeps = _supportsNamedPathDeps(manifest);
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
            rewriteDependencies: (nested) async {
              // A vendored package's manifest may declare deps the parent's
              // resolution never saw (firebase-ios-sdk hides them behind
              // `#if os(macOS)` until normalizeHostManifest exposes them).
              // Leaving those as URL deps forks the identity: this package
              // gets `<name>@<ref>` while the URL dep pulls `<name>` — so
              // resolve the checkout itself and vendor them too.
              var refs = evaluatedRefs;
              final nestedDeps = parseUrlPackageDeps(nested);
              if (evaluateNested != null &&
                  nestedDeps.any(
                    (dep) => !refs.containsKey(_canonicalGitUrl(dep.url)),
                  )) {
                refs = {
                  ...await evaluateNested(nested, destination, nestedDeps),
                  ...evaluatedRefs,
                };
              }
              return _vendorUrlDeps(
                nested,
                vendorDir: vendorDir,
                evaluatedRefs: refs,
                checkout: checkout,
                vendored: vendored,
                requireResolvedRefs: false,
                evaluateNested: evaluateNested,
                fallbackSwiftModules: fallbackSwiftModules,
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
                'path: "${_swiftPath(destination)}")'
          : '.package(path: "${_swiftPath(destination)}")';
      result = result.replaceFirst(dep.match, pathDep);
    }
    return result;
  }

  /// Replaces mode-120000 checkout placeholders produced by Git for Windows.
  ///
  /// With symlink support ([HostSymlinkCapability]) every placeholder becomes
  /// a real symlink, restored by one `git checkout` per checkout; without it
  /// files become hard links (forwarding headers) and directories copies,
  /// through one PowerShell invocation per checkout. A stamp keyed on the
  /// checkout's HEAD records what was produced, so an unchanged checkout is
  /// verified with file-system checks alone and no process is spawned.
  @visibleForTesting
  static Future<bool> materializeCheckoutSymlinks(
    String scratchPath, {
    String git = 'git',
    bool? symlinks,
  }) async {
    final gitExecutable = git == 'git'
        ? await ProcessRunner.locateTool(git)
        : git;
    final checkouts = Directory(p.join(scratchPath, 'checkouts'));
    if (!checkouts.existsSync()) return false;
    var changed = false;
    await for (final repo in checkouts.list(followLinks: false)) {
      if (repo is! Directory) continue;
      changed =
          await materializeGitCheckoutSymlinks(
            repo.path,
            git: gitExecutable,
            stampDir: p.join(scratchPath, '.xcross-symlinks'),
            symlinks: symlinks,
          ) ||
          changed;
    }
    return changed;
  }

  @visibleForTesting
  static Future<bool> materializeGitCheckoutSymlinks(
    String repoPath, {
    String git = 'git',
    String? stampDir,
    bool? symlinks,
  }) async {
    final useSymlinks = symlinks ?? await HostSymlinkCapability.probe();
    final root = p.normalize(p.absolute(repoPath));
    final stamp = File(
      p.join(
        stampDir ?? p.join(p.dirname(root), '.xcross-symlinks'),
        sha256.convert(utf8.encode(root)).toString(),
      ),
    );
    final mode = useSymlinks ? 'symlink' : 'hardlink';
    String fingerprintOf(String identity) => sha256
        .convert(
          utf8.encode(
            'xcross-symlink-materialization-v3\u0000'
            '${Platform.operatingSystem}\u0000$mode\u0000$identity',
          ),
        )
        .toString();

    final head = _gitHeadIdentity(root);
    if (head != null && _materializedLinksIntact(stamp, fingerprintOf(head))) {
      return false;
    }

    final index = await ProcessRunner.run(git, [
      '-C',
      root,
      'ls-files',
      '-s',
      '-z',
    ]);
    if (index.exitCode != 0) {
      throw FlutterBuildError(
        'Could not inspect SwiftPM checkout $root: ${index.stderr}',
      );
    }
    final fingerprint = fingerprintOf(head ?? index.stdout);
    if (head == null && _materializedLinksIntact(stamp, fingerprint)) {
      return false;
    }
    return _materializeGitSymlinks(
      root,
      index.stdout,
      git,
      stamp,
      fingerprint,
      symlinks: useSymlinks,
    );
  }

  /// Contents of `HEAD` plus the ref it points at, read straight from the
  /// repository files, or null when they cannot be resolved that way.
  static String? _gitHeadIdentity(String root) {
    var gitDir = p.join(root, '.git');
    if (FileSystemEntity.isFileSync(gitDir)) {
      final pointer = File(gitDir).readAsStringSync().trim();
      if (!pointer.startsWith('gitdir:')) return null;
      gitDir = p.normalize(
        p.absolute(root, pointer.substring('gitdir:'.length).trim()),
      );
    }
    final headFile = File(p.join(gitDir, 'HEAD'));
    if (!headFile.existsSync()) return null;
    final head = headFile.readAsStringSync().trim();
    if (!head.startsWith('ref:')) return head;
    final ref = head.substring('ref:'.length).trim();
    final commonDirFile = File(p.join(gitDir, 'commondir'));
    final commonDir = commonDirFile.existsSync()
        ? p.normalize(
            p.absolute(gitDir, commonDirFile.readAsStringSync().trim()),
          )
        : gitDir;
    for (final dir in {gitDir, commonDir}) {
      final refFile = File(p.join(dir, ref));
      if (refFile.existsSync()) return '$head\n${refFile.readAsStringSync()}';
    }
    final packed = File(p.join(commonDir, 'packed-refs'));
    if (packed.existsSync()) {
      for (final line in packed.readAsLinesSync()) {
        if (line.endsWith(' $ref')) return '$head\n$line';
      }
    }
    return null;
  }

  static const _stampKindSymlink = 'symlink';
  static const _stampKindForwarder = 'forwarder';
  static const _stampKindHardLink = 'hardlink';
  static const _stampKindDirectory = 'directory';

  /// Whether [stamp] carries [fingerprint] and every link it records still
  /// has the shape it was given.
  static bool _materializedLinksIntact(File stamp, String fingerprint) {
    if (!stamp.existsSync()) return false;
    final Object? decoded;
    try {
      decoded = jsonDecode(stamp.readAsStringSync());
    } on FormatException {
      return false;
    }
    if (decoded is! Map ||
        decoded['version'] != 3 ||
        decoded['fingerprint'] != fingerprint) {
      return false;
    }
    final links = decoded['links'];
    if (links is! List) return false;
    for (final entry in links) {
      if (entry is! Map) return false;
      final path = entry['path'];
      final kind = entry['kind'];
      final target = entry['target'];
      final directory = entry['directory'];
      if (path is! String || kind is! String || target is! String) return false;
      if (kind == _stampKindSymlink && !entry.containsKey('directory')) {
        return false;
      }
      if (directory != null && directory is! bool) return false;
      if (!_linkIntact(path, kind, target, directory: directory as bool?)) {
        return false;
      }
    }
    return true;
  }

  static bool _linkIntact(
    String path,
    String kind,
    String target, {
    bool? directory,
  }) {
    switch (kind) {
      case _stampKindSymlink:
        if (!FileSystemEntity.isLinkSync(path) ||
            Link(path).targetSync() != target) {
          return false;
        }
        final resolved = p.normalize(p.absolute(p.dirname(path), target));
        if (Directory(resolved).existsSync()) {
          return directory != false && Directory(path).existsSync();
        }
        if (File(resolved).existsSync()) {
          return directory != true && File(path).existsSync();
        }
        return directory == null;
      case _stampKindForwarder:
        final file = File(path);
        return !FileSystemEntity.isLinkSync(path) &&
            file.existsSync() &&
            file.readAsStringSync() == target;
      case _stampKindHardLink:
        final file = File(path);
        if (FileSystemEntity.isLinkSync(path) || !file.existsSync()) {
          return false;
        }
        // Git's placeholder holds the target text; anything else was
        // materialized.
        final placeholder = utf8.encode(target);
        return file.lengthSync() != placeholder.length ||
            !_sameBytes(file.readAsBytesSync(), placeholder);
      case _stampKindDirectory:
        return !FileSystemEntity.isLinkSync(path) &&
            Directory(path).existsSync();
      default:
        return false;
    }
  }

  static Future<bool> _materializeGitSymlinks(
    String root,
    String index,
    String git,
    File stamp,
    String fingerprint, {
    required bool symlinks,
  }) async {
    final links = <String, String>{};
    for (final record in index.split('\u0000')) {
      final match = RegExp(
        r'^120000 ([0-9a-f]+) \d+\t(.*)$',
      ).firstMatch(record);
      if (match != null) {
        links[p.normalize(p.join(root, match[2]))] = match[1]!;
      }
    }

    final blobs = await readGitBlobs(root, links.values.toSet(), git);
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

    // A real symlink can preserve a missing optional example. A link used by
    // a declared package target, and every hard-link fallback, needs a target.
    for (final link in links.keys) {
      final target = resolved[link]!;
      if (!Directory(target).existsSync() &&
          !File(target).existsSync() &&
          (!symlinks || _requiredPackageLink(root, link))) {
        throw FlutterBuildError(
          'Symlink target does not exist in SwiftPM checkout: $link -> '
          '$target',
        );
      }
    }

    final records = <Map<String, Object?>>[];
    final changed = symlinks
        ? await _materializeAsSymlinks(
            root,
            links,
            targets,
            resolved,
            git,
            records,
          )
        : await _materializeAsHardLinks(
            root,
            links,
            targets,
            resolved,
            records,
          );

    await stamp.parent.create(recursive: true);
    await stamp.writeAsString(
      jsonEncode({'version': 3, 'fingerprint': fingerprint, 'links': records}),
    );
    return changed;
  }

  static bool _requiredPackageLink(String root, String link) {
    final manifest = File(p.join(root, 'Package.swift'));
    if (!manifest.existsSync()) return true;
    final source = manifest.readAsStringSync();
    final calls = [
      for (final kind in ['.target', '.executableTarget', '.macro'])
        ..._swiftCalls(source, kind),
    ];
    // Plugin builds never compile SwiftPM test targets. A checkout containing
    // only tests may therefore keep their dangling fixture/example links.
    if (calls.isEmpty) return _swiftCalls(source, '.testTarget').isEmpty;
    for (final call in calls) {
      final name = _namedString(call.text, 'name');
      final explicitPath = _namedString(call.text, 'path');
      if (name == null && explicitPath == null) return true;
      final targetRoot = p.normalize(
        p.join(root, explicitPath ?? p.join('Sources', name)),
      );
      if (link != targetRoot && !p.isWithin(targetRoot, link)) continue;
      final relative = p.relative(link, from: targetRoot);
      final excluded = _namedStringList(call.text, 'exclude');
      if (excluded.any(
        (path) => p.equals(relative, path) || p.isWithin(path, relative),
      )) {
        continue;
      }
      final sources = _namedStringList(call.text, 'sources');
      if (sources.isEmpty ||
          sources.any(
            (path) =>
                p.equals(relative, path) ||
                p.isWithin(path, relative) ||
                p.isWithin(relative, path),
          )) {
        return true;
      }
      for (final resource in RegExp(
        r'\.(?:process|copy)\(\s*"([^"]+)"',
      ).allMatches(call.text)) {
        final path = resource[1]!;
        if (p.equals(relative, path) ||
            p.isWithin(path, relative) ||
            p.isWithin(relative, path)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Turns every placeholder into a real symlink carrying Git's own target
  /// text, so the checkout matches its index under `core.symlinks=true` and
  /// later `git reset`/`checkout` runs leave it alone.
  ///
  /// Git restores the links in one `checkout` of the affected paths; it
  /// handles read-only placeholders and, with every target already on disk,
  /// picks the right link kind. Anything it still got wrong is recreated
  /// here directly.
  static Future<bool> _materializeAsSymlinks(
    String root,
    Map<String, String> links,
    Map<String, String> targets,
    Map<String, String> resolved,
    String git,
    List<Map<String, Object?>> records,
  ) async {
    String linkText(String link) => Platform.isWindows
        ? targets[link]!.replaceAll('/', r'\')
        : targets[link]!;
    bool intact(String link) =>
        _linkIntact(link, _stampKindSymlink, linkText(link));

    final pending = [
      for (final link in links.keys)
        if (!intact(link)) link,
    ];
    for (final link in links.keys) {
      records.add({
        'path': link,
        'kind': _stampKindSymlink,
        'target': linkText(link),
        'directory': Directory(resolved[link]!).existsSync()
            ? true
            : File(resolved[link]!).existsSync()
            ? false
            : null,
      });
    }
    if (pending.isEmpty) return false;

    final checkout = await ProcessRunner.start(git, [
      '-c',
      'core.symlinks=true',
      if (Platform.isWindows) ...const ['-c', 'core.longpaths=true'],
      '-C',
      root,
      'checkout',
      '--force',
      '--pathspec-from-file=-',
      '--pathspec-file-nul',
      '--',
    ]);
    checkout.stdin.write(
      pending.map((link) => p.relative(link, from: root)).join('\u0000'),
    );
    await checkout.stdin.close();
    final stderr = await checkout.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    await checkout.stdout.drain<void>();
    if (await checkout.exitCode != 0) {
      throw FlutterBuildError(
        'Could not restore symlinks in SwiftPM checkout $root: $stderr',
      );
    }

    for (final link in pending) {
      if (intact(link)) continue;
      final type = FileSystemEntity.typeSync(link, followLinks: false);
      if (type == FileSystemEntityType.link) {
        Link(link).deleteSync();
      } else if (type == FileSystemEntityType.directory) {
        Directory(link).deleteSync(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        await _clearPlaceholderAttributes(link);
        File(link).deleteSync();
      }
      _createRelativeLink(link, linkText(link));
      if (!intact(link)) {
        throw FlutterBuildError(
          'Could not create symlink in SwiftPM checkout: $link -> '
          '${linkText(link)}',
        );
      }
    }
    return true;
  }

  /// `Link.create` decides between a file and a directory symlink by looking
  /// at the target relative to the working directory, so a relative target
  /// is only typed correctly from the link's own directory.
  static void _createRelativeLink(String link, String target) {
    if (!Platform.isWindows) {
      Link(link).createSync(target);
      return;
    }
    final previous = Directory.current;
    Directory.current = p.dirname(link);
    try {
      Link(link).createSync(target);
    } finally {
      Directory.current = previous;
    }
  }

  /// Fallback for hosts that cannot create symlinks: files become hard links
  /// (forwarding headers), directories copies. Read-only placeholders are
  /// cleared, removed, and hard-linked in one PowerShell process; the rest is
  /// plain file I/O.
  static Future<bool> _materializeAsHardLinks(
    String root,
    Map<String, String> links,
    Map<String, String> targets,
    Map<String, String> resolved,
    List<Map<String, Object?>> records,
  ) async {
    final replace = <String>[];
    final hardLinks = <(String, String)>[];
    final forwarders = <(String, String)>[];
    final directories = <String>[];
    var changed = false;

    // Directories are ordered so a link inside another link's target is
    // materialized before that target is copied.
    final ordered = <String>[];
    final visiting = <String>{};
    void order(String link) {
      if (ordered.contains(link)) return;
      if (!visiting.add(link)) {
        throw FlutterBuildError('Symlink cycle in SwiftPM checkout: $link');
      }
      final target = resolved[link]!;
      if (Directory(target).existsSync()) {
        for (final nested in links.keys) {
          if (p.isWithin(target, nested)) order(nested);
        }
      }
      visiting.remove(link);
      ordered.add(link);
    }

    for (final link in links.keys) {
      order(link);
    }

    for (final link in ordered) {
      final target = resolved[link]!;
      if (Directory(target).existsSync()) {
        records.add({
          'path': link,
          'kind': _stampKindDirectory,
          'target': target,
        });
        if (FileSystemEntity.typeSync(link, followLinks: false) !=
            FileSystemEntityType.directory) {
          replace.add(link);
          changed = true;
        }
        directories.add(link);
        continue;
      }
      final forwarder = Platform.isWindows
          ? _headerForwarder(link, target)
          : null;
      if (!Platform.isWindows) {
        records.add({
          'path': link,
          'kind': _stampKindHardLink,
          'target': targets[link],
        });
        changed = await _syncFile(File(target), link) || changed;
        continue;
      }
      if (forwarder != null) {
        records.add({
          'path': link,
          'kind': _stampKindForwarder,
          'target': forwarder,
        });
        if (_linkIntact(link, _stampKindForwarder, forwarder)) continue;
        replace.add(link);
        forwarders.add((link, forwarder));
      } else {
        records.add({
          'path': link,
          'kind': _stampKindHardLink,
          'target': targets[link],
        });
        if (_linkIntact(link, _stampKindHardLink, targets[link]!)) {
          continue;
        }
        replace.add(link);
        hardLinks.add((link, target));
      }
      changed = true;
    }

    if (Platform.isWindows && (replace.isNotEmpty || hardLinks.isNotEmpty)) {
      await _runPlaceholderScript(root, replace: replace, hardLinks: hardLinks);
    }
    for (final (link, forwarder) in forwarders) {
      await File(link).writeAsString(forwarder);
    }
    for (final link in directories) {
      final target = resolved[link]!;
      if (!Platform.isWindows) {
        await _deleteUnless(link, FileSystemEntityType.directory);
      }
      changed = await _syncDirectory(target, link) || changed;
    }
    return changed;
  }

  /// One PowerShell process that clears the read-only bit Git for Windows
  /// puts on placeholders, deletes them, and creates the hard links.
  static Future<void> _runPlaceholderScript(
    String root, {
    required List<String> replace,
    required List<(String, String)> hardLinks,
  }) async {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final script = StringBuffer()
      ..writeln(r"$ErrorActionPreference = 'Stop'")
      ..writeln(r'$readOnly = [IO.FileAttributes]::ReadOnly')
      ..writeln(r'$reparse = [IO.FileAttributes]::ReparsePoint')
      ..writeln(r'foreach ($path in @(')
      ..writeln(replace.map(quote).join(',\n'))
      ..writeln(')) {')
      ..writeln(
        r'  if (-not ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path))) { continue }',
      )
      ..writeln(r'  $attributes = [IO.File]::GetAttributes($path)')
      ..writeln(
        r'  if ($attributes -band $readOnly) { [IO.File]::SetAttributes($path, $attributes -band (-bnot $readOnly)) }',
      )
      ..writeln(r'  if ([IO.Directory]::Exists($path)) {')
      ..writeln(
        r'    if ($attributes -band $reparse) { [IO.Directory]::Delete($path) } else { Remove-Item -LiteralPath $path -Recurse -Force }',
      )
      ..writeln(r'  } else { [IO.File]::Delete($path) }')
      ..writeln('}')
      // Hashtables, not nested arrays: PowerShell flattens `@(@(a, b))`.
      ..writeln(r'foreach ($pair in @(')
      ..writeln(
        hardLinks
            .map(
              (pair) =>
                  '@{ Path = ${quote(pair.$1)}; Target = ${quote(pair.$2)} }',
            )
            .join(',\n'),
      )
      ..writeln(')) {')
      ..writeln(
        r'  New-Item -ItemType HardLink -Path $pair.Path -Value $pair.Target | Out-Null',
      )
      ..writeln('}');
    final scriptFile = File(
      p.join(
        Directory.systemTemp.path,
        'xcross-placeholders-$pid-${DateTime.now().microsecondsSinceEpoch}.ps1',
      ),
    );
    await scriptFile.writeAsString(script.toString());
    try {
      final result = await ProcessRunner.run(
        await ProcessRunner.locateTool('powershell'),
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptFile.path,
        ],
      );
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Could not materialize checkout placeholders: ${result.stderr}',
          root,
        );
      }
    } finally {
      if (scriptFile.existsSync()) await scriptFile.delete();
    }
  }

  @visibleForTesting
  static Future<Map<String, List<int>>> readGitBlobs(
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
    // Start draining before writing a single request. `cat-file --batch`
    // answers each object as it reads it, so its stdout fills up while this
    // process is still feeding stdin. A pipe buffer is finite (64 KiB on
    // Windows), so writing the whole request list first deadlocks as soon as
    // the replies outgrow it: git blocks writing output nobody is reading,
    // and this process blocks writing input git has stopped reading. A
    // checkout with enough symlinked headers (SDWebImage) reliably crosses
    // that line, which is what turned a CI build into a multi-hour hang.
    final outputFuture = process.stdout.fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    final errorFuture = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    // Backstop for any remaining way this child could stop making progress.
    // Reading local objects out of an existing checkout is a sub-second
    // operation, so a run this long is a hang, not slow work.
    const timeout = Duration(minutes: 5);
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      unawaited(ProcessRunner.killTree(process));
    });
    final List<int> output;
    final String error;
    final int exitCode;
    try {
      for (final objectId in objectIds) {
        process.stdin.writeln(objectId);
      }
      // A killed child's stdin is a broken pipe; the failure that matters is
      // reported from the exit code below.
      try {
        await process.stdin.flush();
        await process.stdin.close();
      } on Object catch (_) {}
      exitCode = await process.exitCode;
      output = await outputFuture;
      error = await errorFuture;
    } finally {
      timer.cancel();
    }
    if (timedOut) {
      throw FlutterBuildError(
        'Timed out after ${timeout.inMinutes} minutes reading symlink targets '
        'in SwiftPM checkout $repoPath.',
      );
    }
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
    // Last line of defence behind [nonInteractiveGitEnvironment]. That
    // environment cannot clear a *URL-scoped* helper — `credential
    // .https://github.com.helper` is a different key per host, so no fixed
    // reset covers them — and a helper that opens UI still blocks on a
    // build that has no one watching. A network stall does the same.
    // Generous enough that a cold clone of a large dependency finishes
    // (firebase-ios-sdk takes well under a minute on CI), short enough
    // that a stuck one is reported the same hour.
    const timeout = Duration(minutes: 10);
    // `core.symlinks=true` on every command, not just the clone: a later
    // `reset --hard` under the default `false` would see the real symlinks
    // as modified files and overwrite them with placeholders again.
    final gitConfig = Platform.isWindows
        ? [
            '-c',
            'core.longpaths=true',
            if (await HostSymlinkCapability.probe()) ...[
              '-c',
              'core.symlinks=true',
            ],
          ]
        : const <String>[];
    // Some packages keep their sources in a submodule (libwebp-Xcode vendors
    // webmproject/libwebp), so a submodule-less checkout compiles into
    // "unknown type name WebPDemuxer" once a dependent target imports it.
    Future<void> updateSubmodules() async {
      if (!File(p.join(destination, '.gitmodules')).existsSync()) return;
      await ProcessRunner.runChecked(
        git,
        [
          ...gitConfig,
          '-C',
          destination,
          'submodule',
          'update',
          '--init',
          '--recursive',
          '--depth',
          '1',
        ],
        environment: environment,
        timeout: timeout,
        label: 'git submodule update ${p.basename(destination)}',
      );
    }

    if (File(p.join(destination, '.git')).existsSync() ||
        Directory(p.join(destination, '.git')).existsSync()) {
      final head = await ProcessRunner.run(
        git,
        [...gitConfig, '-C', destination, 'rev-parse', '--verify', 'HEAD'],
        environment: environment,
        timeout: timeout,
      );
      if (head.exitCode == 0 &&
          head.stdout.trim().toLowerCase() == ref.toLowerCase()) {
        await ProcessRunner.runChecked(
          git,
          [...gitConfig, '-C', destination, 'reset', '--hard', 'HEAD'],
          environment: environment,
          timeout: timeout,
          label: 'git reset vendored package',
        );
        await updateSubmodules();
        return;
      }
    }
    await _deleteEntity(destination);
    await destDir.parent.create(recursive: true);

    final shallow = await ProcessRunner.run(
      git,
      [
        ...gitConfig,
        'clone',
        '--depth',
        '1',
        '--branch',
        ref,
        url,
        destination,
      ],
      environment: environment,
      timeout: timeout,
    );
    if (shallow.exitCode == 0) {
      await updateSubmodules();
      return;
    }

    await _deleteEntity(destination);
    await Directory(destination).create(recursive: true);
    final init = await ProcessRunner.run(
      git,
      [...gitConfig, '-C', destination, 'init'],
      environment: environment,
      timeout: timeout,
    );
    final fetch = init.exitCode == 0
        ? await ProcessRunner.run(
            git,
            [
              ...gitConfig,
              '-C',
              destination,
              'fetch',
              '--depth',
              '1',
              url,
              ref,
            ],
            environment: environment,
            timeout: timeout,
          )
        : init;
    final checkout = fetch.exitCode == 0
        ? await ProcessRunner.run(
            git,
            [
              ...gitConfig,
              '-C',
              destination,
              'checkout',
              '--detach',
              'FETCH_HEAD',
            ],
            environment: environment,
            timeout: timeout,
          )
        : fetch;
    if (checkout.exitCode == 0) {
      await updateSubmodules();
      return;
    }

    await _deleteEntity(destination);
    await ProcessRunner.runChecked(
      git,
      [...gitConfig, 'clone', url, destination],
      environment: environment,
      timeout: timeout,
      label: 'git clone $url',
    );
    await ProcessRunner.runChecked(
      git,
      [...gitConfig, '-C', destination, 'checkout', ref],
      environment: environment,
      timeout: timeout,
      label: 'git checkout $ref',
    );
    await updateSubmodules();
  }

  static Future<bool> _normalizeVendoredPackageManifests(
    String packageDir, {
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
    Future<String> Function(String manifest)? rewriteDependencies,
  }) async {
    var changed = false;
    final manifests = <File>[];
    await for (final entity in Directory(packageDir).list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name != 'Package.swift' &&
          !(name.startsWith('Package@') && name.endsWith('.swift'))) {
        continue;
      }
      manifests.add(entity);
    }
    Future<void> update(File manifest, String original, String updated) async {
      if (updated == original) return;
      await _clearPlaceholderAttributes(manifest.path);
      await manifest.writeAsString(updated);
      // Vendoring restores the upstream manifest with `git reset --hard`
      // before each build, so these host fixes are re-applied every run and
      // land with a fresh timestamp even though the bytes never change.
      // SwiftPM invalidates a package's whole target set on its manifest
      // timestamp, so that alone recompiled the entire graph each build.
      await _stampByContent(manifest.path, updated);
      changed = true;
    }

    // Host fixes land on disk first so a nested `swift package resolve`
    // (needed when the parent's pins miss deps hidden behind `#if os(macOS)`)
    // sees the same manifests the final build will.
    for (final manifest in manifests) {
      final original = await manifest.readAsString();
      final normalized = await synthesizeBinaryFallbackCompatibility(
        normalizeHostManifest(original),
        packageDir: packageDir,
        consumedProducts: consumedProducts,
        // The source-fallback block only activates where
        // [swiftProcessEnvironment] sets EXPERIMENTAL_SPM_BUILDS (Windows).
        // Elsewhere the binary product is used, its Swift half is not a
        // separate module, and injecting `import <fallback>` into consumers
        // fails with "no such module" (e.g. `SentrySwift` in sentry_flutter).
        fallbackSwiftModules: _sourceFallbackActive
            ? fallbackSwiftModules
            : null,
      );
      await update(manifest, original, normalized);
    }
    if (rewriteDependencies != null) {
      for (final manifest in manifests) {
        final original = await manifest.readAsString();
        await update(manifest, original, await rewriteDependencies(original));
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
    Map<String, String> stagedPackageDirs = const {},
  }) {
    final imports = StringBuffer();
    final registrations = StringBuffer();
    var pluginCount = 0;
    for (final plugin in plugins) {
      final pluginClass = plugin.pluginClassIos;
      if (pluginClass == null) continue;
      pluginCount++;
      imports.writeln('import ${plugin.name}');
      final registration = StringBuffer();
      if (verbose) {
        registration.writeln('''
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
        registration.writeln('''
    if let registrar = registry.registrar(forPlugin: "$pluginClass") {
        $pluginClass.register(with: registrar)
    }''');
      }
      final availableFrom = plugin.pluginClassIosAvailabilityIn(
        stagedPackage: stagedPackageDirs[plugin.name],
      );
      if (availableFrom == null) {
        registrations.write(registration);
      } else {
        registrations.writeln('''
    if #available(iOS $availableFrom, *) {''');
        registrations.write(registration);
        registrations.writeln('    } else {');
        if (verbose) {
          registrations.writeln(
            '''
        failures.append("${plugin.name} ($pluginClass): requires iOS $availableFrom")
        NSLog("[xcross] skipped plugin ${plugin.name} ($pluginClass): requires iOS $availableFrom")''',
          );
        }
        registrations.writeln('    }');
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
  ///
  /// Skipping the write is not enough on its own. Several of these files are
  /// staged, reset, or regenerated from scratch earlier in the same build, so
  /// the write is genuinely necessary yet still produces the bytes the last
  /// build compiled. The timestamp is therefore derived from the content, so
  /// identical output always presents SwiftPM with an identical timestamp.
  static Future<void> _writeStable(String path, String content) async {
    final file = File(path);
    if (!(file.existsSync() && await file.readAsString() == content)) {
      await _writeAtomic(path, utf8.encode(content));
    }
    await _stampByContent(path, content);
  }

  /// Sets [path]'s modification time to a function of [content].
  ///
  /// For a file that must be rewritten on every run because something else
  /// reverts it first, "write only when changed" cannot keep the timestamp
  /// stable. Deriving the timestamp from the bytes can: the same content
  /// always yields the same timestamp, so SwiftPM sees no change, while new
  /// content still moves it.
  ///
  /// Failures are ignored. A timestamp that cannot be set costs a rebuild,
  /// which is the behaviour this avoids, not a broken build.
  static Future<void> _stampByContent(String path, String content) =>
      _stampByContentBytes(path, utf8.encode(content));

  /// [_stampByContent] for content already encoded as bytes.
  static Future<void> _stampByContentBytes(String path, List<int> bytes) async {
    try {
      final digest = sha256.convert(bytes).bytes;
      // A fixed, arbitrary epoch plus a digest-derived offset. The offset is
      // bounded to roughly a decade so the result is always a valid, plainly
      // historical timestamp rather than something a tool might reject.
      final offset =
          ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3])
              .toUnsigned(32) %
          const Duration(days: 3650).inSeconds;
      await File(
        path,
      ).setLastModified(DateTime.utc(2010).add(Duration(seconds: offset)));
    } on Object {
      // Deliberately ignored: see above.
    }
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

  static String _ioPath(String path) => HostPaths.long(path);

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
    // Staging re-copies plugin sources on every build, and a later repair
    // pass rewrites some of them, so a file can be legitimately written
    // twice per build while ending at the same bytes it had before. SwiftPM
    // invalidates on timestamps, so without a content-derived stamp those
    // rewrites recompile the target, and everything downstream of it, on
    // every incremental build.
    await _stampByContentBytes(destination, bytes);
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
    final ioSource = _ioPath(source);
    final ioDestination = _ioPath(destination);
    final root = artifactRoot == null
        ? p.normalize(p.absolute(ioSource))
        : _ioPath(artifactRoot);
    await Directory(ioDestination).create(recursive: true);
    await for (final entity in Directory(ioSource).list(followLinks: false)) {
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
