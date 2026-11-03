import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/app_resource_compiler.dart';
import 'package:xcross/src/shared/artifact/plist_mutations.dart';
import 'package:xcross/src/shared/flutter/build/app_extension_builder.dart';
import 'package:xcross/src/shared/flutter/build/bundle_pkg_info.dart';
import 'package:xcross/src/shared/flutter/build/info_plist.dart';
import 'package:xcross/src/shared/flutter/build/internal/staged_directory_swap.dart';
import 'package:xcross/src/shared/flutter/build/ios_bundle_resources.dart';
import 'package:xcross/src/shared/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/constants.dart';
import 'package:xcross/src/shared/flutter/extensions/app_extension_plist.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dynamic_product.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/static_framework_stubs.dart';
import 'package:xcross/src/target/shared/flutter/xcode_build_metadata.dart';

@internal
final class FlutterBundleAssembler<T extends PlatformHostInterface>
    implements FlutterAssembleStep<T> {
  FlutterBundleAssembler(this.context);
  final FlutterBuildContext<T> context;
  FlutterBuildRuntime<T> get runtime => context.runtime;
  String get projectRoot => context.projectRoot;
  String get bundleId => context.bundleId;
  String get appName => context.appName;
  FlutterBuildOptions get options => context.options;
  IosBundleVersions get _versions => context.versions;
  String get outputDirectory => runtime.policy.outputDirectory(projectRoot);
  @override
  Future<String> assemble(FlutterLinkedArtifacts linked) =>
      _assembleAndPersistBundle(
        appFramework: linked.compiled.appFramework,
        xcframework: linked.runner.xcframework,
        runnerBinary: linked.runner.runnerBinary,
        sdkName: linked.runner.sdkName,
        sdkPath: linked.runner.sdkPath,
        pluginLibraries: linked.compiled.plugins?.dylibPaths ?? const [],
        pluginProducts: linked.compiled.plugins?.dynamicProducts ?? const [],
        pluginFrameworks: linked.compiled.plugins?.frameworkPaths ?? const [],
        resourceBundles: linked.compiled.plugins?.resourceBundles ?? const [],
        nativeAssetFrameworks: linked.compiled.nativeAssets.frameworks,
        deploymentTarget: context.deploymentTarget,
        extensions: linked.extensions,
      );

  Future<String> _assembleAndPersistBundle({
    required String appFramework,
    required String xcframework,
    required String runnerBinary,
    required String sdkName,
    required String? sdkPath,
    required List<String> pluginLibraries,
    required List<SwiftPmDynamicProduct> pluginProducts,
    required List<String> pluginFrameworks,
    required List<SwiftPmResourceBundle> resourceBundles,
    required List<String> nativeAssetFrameworks,
    required IosDeploymentTarget deploymentTarget,
    required List<BuiltAppExtension> extensions,
  }) async {
    final dest = runtime.host.paths.context.join(
      outputDirectory,
      '$appName.app',
    );
    // Stage beside the destination (same volume) and rename into place, so
    // the destination only changes once everything is in place and the
    // finished app is never copied a second time.
    final swap = StagedDirectorySwap(
      fileSystem: runtime.host.fileSystem,
      paths: runtime.host.paths.context,
      copier: runtime.directoryCopier,
    );
    final tmp = await swap.createStaging(dest);

    try {
      await _stageBundle(
        bundleDir: tmp.path,
        appFramework: appFramework,
        flutterFramework: runtime.host.paths.context.join(
          runtime.policy.selectEngineSlice(xcframework),
          'Flutter.framework',
        ),
        runnerBinary: runnerBinary,
        sdkName: sdkName,
        sdkPath: sdkPath,
        pluginLibraries: pluginLibraries,
        pluginProducts: pluginProducts,
        pluginFrameworks: pluginFrameworks,
        resourceBundles: resourceBundles,
        nativeAssetFrameworks: nativeAssetFrameworks,
        deploymentTarget: deploymentTarget,
        extensions: extensions,
      );

      await swap.swap(tmp, dest);
    } catch (_) {
      await swap.discard(tmp);
      rethrow;
    }
    await _publishDebugSymbols(
      appFramework: appFramework,
      engineSlice: runtime.policy.selectEngineSlice(xcframework),
      nativeAssetFrameworks: nativeAssetFrameworks,
    );

    return dest;
  }

  /// Replaces the dSYMs beside the `.app` with those of this build, as
  /// `flutter build ios` leaves them: `App.framework.dSYM`, the engine's
  /// `Flutter.framework.dSYM`, and one per native asset framework. Debug
  /// builds have none, so they only remove stale ones.
  Future<void> _publishDebugSymbols({
    required String appFramework,
    required String engineSlice,
    required List<String> nativeAssetFrameworks,
  }) async {
    final paths = runtime.host.paths.context;
    final fs = runtime.host.fileSystem;
    final wanted = <String, String>{
      if (options.buildMode.isPrecompiled)
        for (final dsym in [
          '$appFramework.dSYM',
          paths.join(engineSlice, 'dSYMs', 'Flutter.framework.dSYM'),
          for (final framework in nativeAssetFrameworks) '$framework.dSYM',
        ])
          if (fs.directory(dsym).existsSync()) paths.basename(dsym): dsym,
    };
    final output = fs.directory(outputDirectory);
    await for (final entity in output.list(followLinks: false)) {
      final name = paths.basename(entity.path);
      if (name.endsWith('.framework.dSYM') && !wanted.containsKey(name)) {
        await entity.delete(recursive: true);
        await _deleteIfExists(fs.file(_dsymStamp(name)));
      }
    }
    for (final MapEntry(key: name, value: source) in wanted.entries) {
      final dest = fs.directory(paths.join(outputDirectory, name));
      final stamp = fs.file(_dsymStamp(name));
      final signature = await _treeSignature(source);
      if (dest.existsSync() &&
          stamp.existsSync() &&
          await stamp.readAsString() == signature) {
        continue;
      }
      if (dest.existsSync()) await dest.delete(recursive: true);
      await runtime.directoryCopier.copy(source, dest.path);
      await stamp.writeAsString(signature);
    }
  }

  String _dsymStamp(String name) =>
      runtime.host.paths.context.join(outputDirectory, '.$name.stamp');

  static Future<void> _deleteIfExists(File file) async {
    if (file.existsSync()) await file.delete();
  }

  /// Cheap change detector for a dSYM: its source path plus every file's
  /// relative path, size, and mtime (no content reads).
  Future<String> _treeSignature(String root) async {
    final paths = runtime.host.paths.context;
    final lines = <String>[root];
    await for (final entity
        in runtime.host.fileSystem.directory(root).list(recursive: true)) {
      if (entity is! File) continue;
      final stat = entity.statSync();
      lines.add(
        '${paths.relative(entity.path, from: root)}\t${stat.size}\t'
        '${stat.modified.microsecondsSinceEpoch}',
      );
    }
    lines.sort();
    return lines.join('\n');
  }

  /// Lay out the `.app` contents under [bundleDir]: the Runner executable,
  /// the embedded frameworks and plugin dylibs, storyboards, and `Info.plist`.
  Future<void> _stageBundle({
    required String bundleDir,
    required String appFramework,
    required String flutterFramework,
    required String runnerBinary,
    required String sdkName,
    required String? sdkPath,
    required List<String> pluginLibraries,
    required List<SwiftPmDynamicProduct> pluginProducts,
    required List<String> pluginFrameworks,
    required List<SwiftPmResourceBundle> resourceBundles,
    required List<String> nativeAssetFrameworks,
    required IosDeploymentTarget deploymentTarget,
    required List<BuiltAppExtension> extensions,
  }) async {
    final frameworksDir = runtime.host.paths.context.join(
      bundleDir,
      'Frameworks',
    );
    await runtime.host.fileSystem
        .directory(frameworksDir)
        .create(recursive: true);

    final runnerDest = runtime.host.paths.context.join(bundleDir, 'Runner');
    await runtime.host.fileSystem
        .file(runnerBinary)
        .copy(runtime.host.fileSystem.file(runnerDest).path);
    runtime.runner.makeExecutable(runnerDest);

    await runtime.directoryCopier.copy(
      flutterFramework,
      runtime.host.paths.context.join(frameworksDir, 'Flutter.framework'),
    );
    await runtime.directoryCopier.copy(
      appFramework,
      runtime.host.paths.context.join(frameworksDir, 'App.framework'),
    );
    final build = sdkPath == null
        ? null
        : XcodeBuildMetadata.load(
            runtime.host.fileSystem,
            runtime.host.paths.context,
            sdkPath,
          );
    // Dynamic SwiftPM products ship as frameworks, never loose dylibs.
    await runtime.frameworks.copyPluginLibraries(
      pluginProducts,
      frameworksDir,
      infoPlist: (product) => runtime.policy.transformPlist(
        swiftPmDynamicProductInfoPlist(
          product,
          deploymentTarget: deploymentTarget.version,
          device: sdkName.startsWith('iphoneos'),
        ),
        sdkName: sdkName,
        build: build,
      ),
    );
    await runtime.frameworks.copyNativeAssetFrameworks(
      nativeAssetFrameworks,
      frameworksDir,
    );
    final embedded = await runtime.frameworks.copyMissingFrameworks(
      pluginFrameworks,
      frameworksDir,
    );
    await runtime.nativeAssetFrameworks.thinEmbedded(
      embedded,
      lipo: () => runtime.nativeTools.locateLlvmTool('llvm-lipo'),
    );
    // Static SwiftPM binary frameworks: Xcode embeds a stub of each so
    // their privacy manifests and resource bundles ship.
    await StaticFrameworkStubs(
      fileSystem: runtime.host.fileSystem,
      paths: runtime.host.paths.context,
      copier: runtime.directoryCopier,
    ).embedLinked(
      pluginLibraries,
      frameworksDir,
      simulator: !sdkName.startsWith('iphoneos'),
      sdkVersion: StaticFrameworkStubs.sdkVersionOf(sdkName),
    );
    // SwiftPM plugin resource bundles (privacy manifests and other
    // resources) sit in the app root, as Xcode embeds them.
    await runtime.frameworks.copyResourceBundles(
      resourceBundles,
      bundleDir,
      warn: runtime.runner.log.logWarn,
      infoPlist: (bundle, region) => runtime.policy.transformPlist(
        swiftPmResourceBundleInfoPlist(
          bundle,
          developmentRegion: region,
          deploymentTarget: deploymentTarget.version,
          device: sdkName.startsWith('iphoneos'),
          paths: runtime.host.paths.context,
        ),
        sdkName: sdkName,
        build: build,
      ),
    );

    await _embedAppExtensions(bundleDir, extensions);
    final staged = await runtime.resources.stage(
      projectRoot: projectRoot,
      bundleDir: bundleDir,
      configuration: _xcodeConfiguration,
    );
    await _writeInfoPlist(
      bundleDir,
      deploymentTarget: deploymentTarget,
      sdkName: sdkName,
      sdkPath: sdkPath,
      resources: staged,
    );
    // After Info.plist is final: the ad-hoc signature hashes it, and carries
    // the target's entitlements for re-signers and `xcross flutter run`.
    if (runtime.policy.embedsEntitlements) {
      final entitled = runtime.entitlements.resolve(
        projectRoot: projectRoot,
        bundleDir: bundleDir,
        configuration: _xcodeConfiguration,
      );
      for (final binary in await runtime.entitlements.embed(entitled)) {
        runtime.runner.log.logTrace('signed ad-hoc with entitlements: $binary');
      }
    }
    for (final binary in await runtime.signatures.refresh(bundleDir)) {
      runtime.runner.log.logTrace('refreshed ad-hoc signature of $binary');
    }
  }

  /// The Xcode build configuration this build corresponds to, as
  /// `flutter build ios` picks it: `Release-<flavor>` when the project
  /// declares one for the flavor, otherwise `Debug`/`Profile`/`Release`.
  String get _xcodeConfiguration {
    final base = switch (options.buildMode) {
      FlutterBuildMode.debug => 'Debug',
      FlutterBuildMode.profile => 'Profile',
      FlutterBuildMode.release => 'Release',
    };
    final flavor = options.flavor;
    if (flavor == null || flavor.isEmpty) return base;
    final flavored = '$base-$flavor';
    final pbxproj = runtime.projects.findPbxproj(projectRoot);
    final project = pbxproj == null
        ? null
        : runtime.projects.parseFile(pbxproj);
    final declared = project
        ?.byIsa('XCBuildConfiguration')
        .any((configuration) => configuration.string('name') == flavored);
    return declared ?? false ? flavored : base;
  }

  /// Copy each built `.appex` into the app's `PlugIns` directory, the only
  /// location iOS looks for embedded app extensions.
  Future<void> _embedAppExtensions(
    String bundleDir,
    List<BuiltAppExtension> extensions,
  ) async {
    if (extensions.isEmpty) return;
    final plugInsDir = runtime.host.paths.context.join(bundleDir, 'PlugIns');
    await runtime.host.fileSystem.directory(plugInsDir).create(recursive: true);
    for (final extension in extensions) {
      await runtime.directoryCopier.copy(
        extension.bundlePath,
        runtime.host.paths.context.join(
          plugInsDir,
          extension.extension.bundleName,
        ),
      );
    }
  }

  /// Generate and write `Info.plist` into [bundleDir] with `$(VAR)`
  /// substitution, mandatory iOS keys, compiled app icon and launch screen,
  /// storyboard stripping, and ObjC class name normalization.
  Future<void> _writeInfoPlist(
    String bundleDir, {
    required IosDeploymentTarget deploymentTarget,
    required String sdkName,
    required String? sdkPath,
    required StagedIosResources resources,
  }) async {
    var plistXml = await _loadPlistTemplate();

    // ORDER MATTERS: vars must be expanded before forcing keys so that forced
    // keys see already-substituted values from the template, and before
    // storyboard stripping so $(VAR)-valued storyboard names are resolved
    // before the .storyboardc filesystem probe.
    plistXml = InfoPlist.expandXmlVars(
      plistXml,
      await buildSubstitutionMap(sdkName: sdkName),
    );
    if (options.buildName != null ||
        !plistXml.contains('<key>CFBundleShortVersionString</key>')) {
      plistXml = PlistMutations.setPlistString(
        plistXml,
        'CFBundleShortVersionString',
        _versions.shortVersion,
      );
    }
    if (options.buildNumber != null ||
        !plistXml.contains('<key>CFBundleVersion</key>')) {
      plistXml = PlistMutations.setPlistString(
        plistXml,
        'CFBundleVersion',
        _versions.bundleVersion,
      );
    }
    plistXml = InfoPlist.applyIosRequiredKeys(
      plistXml,
      bundleId: bundleId,
      deploymentTarget: deploymentTarget,
      deviceFamily: resources.deviceFamily,
    );
    plistXml = runtime.policy.transformPlist(
      plistXml,
      sdkName: sdkName,
      build: sdkPath == null
          ? null
          : XcodeBuildMetadata.load(
              runtime.host.fileSystem,
              runtime.host.paths.context,
              sdkPath,
            ),
    );
    if (options.buildMode != FlutterBuildMode.release) {
      plistXml = InfoPlist.applyDebugVmServiceDiscovery(plistXml);
    }
    // Before storyboard stripping: a launch storyboard that cannot be
    // compiled is translated into `UILaunchScreen` here, and stripping then
    // only removes what could not be translated.
    plistXml = await _compileAppResources(
      plistXml,
      bundleDir: bundleDir,
      deploymentTarget: deploymentTarget,
      resources: resources,
    );
    plistXml = runtime.storyboards.stripUnsatisfiableStoryboards(
      plistXml,
      bundleDir,
    );
    plistXml = InfoPlist.applySceneLifecycle(plistXml);
    plistXml = InfoPlist.normalizeObjCClassNames(plistXml);
    // Carry the app's own App Groups forward so the sign/install stage can
    // provision them alongside its extensions'.
    plistXml = AppExtensionPlist.setAppGroups(plistXml, _hostAppGroups());

    await runtime.host.fileSystem
        .file(runtime.host.paths.context.join(bundleDir, 'Info.plist'))
        .writeAsString(plistXml);
    await runtime.host.fileSystem
        .file(
          runtime.host.paths.context.join(bundleDir, BundlePkgInfo.fileName),
        )
        .writeAsString(BundlePkgInfo.contentsFor(plistXml));
  }

  /// Compiles the target's asset catalogs into `Assets.car` and loose app
  /// icons, and translates an uncompiled launch storyboard into
  /// `UILaunchScreen`, returning [plistXml] with the matching keys.
  Future<String> _compileAppResources(
    String plistXml, {
    required String bundleDir,
    required IosDeploymentTarget deploymentTarget,
    required StagedIosResources resources,
  }) {
    final paths = runtime.host.paths.context;
    final launchName = AppResourceCompiler.launchStoryboardNameOf(plistXml);
    return runtime.resourceCompiler.compile(
      bundleDir: bundleDir,
      infoPlistXml: plistXml,
      catalogs: resources.assetCatalogs,
      deploymentTarget: deploymentTarget.version,
      appIconName: resources.appIconName,
      alternateAppIconNames: resources.alternateAppIconNames,
      includeAllAppIcons: resources.includeAllAppIcons,
      accentColorName: resources.accentColorName,
      launchStoryboard: launchName == null
          ? null
          : resources.storyboard(launchName, paths),
      deviceFamilies: AppResourceCompiler.deviceFamiliesOf(plistXml),
      carCacheDirectory: runtime.policy.buildDirectory(
        projectRoot,
        'xcross-asset-catalog',
      ),
    );
  }

  /// App Groups declared by the application target's entitlements file.
  List<String> _hostAppGroups() {
    final extensionGroups = runtime.extensions.applicationEntitlements(
      projectRoot,
    );
    return runtime.extensions.readAppGroups(extensionGroups);
  }

  /// Read `ios/Runner/Info.plist`, falling back to [InfoPlist.fallback].
  Future<String> _loadPlistTemplate() async {
    final plistFile = runtime.host.fileSystem.file(
      runtime.host.paths.context.join(
        projectRoot,
        'ios',
        'Runner',
        'Info.plist',
      ),
    );
    if (plistFile.existsSync()) {
      final plistSource = await plistFile.readAsString();
      return plistSource;
    }
    return InfoPlist.fallback;
  }

  /// Build the `$(VAR)` substitution map.
  ///
  /// Precedence (lowest → highest):
  ///   1. Hard-coded defaults (`1.0.0` / `1`).
  ///   2. `Debug.xcconfig` and its includes in textual order, falling back
  ///      to `Generated.xcconfig` only when no Debug file exists.
  ///   3. Explicit `--build-name` / `--build-number` CLI flags.
  @visibleForTesting
  Future<Map<String, String>> buildSubstitutionMap({String? sdkName}) async {
    final selectedSdk = sdkName ?? runtime.target.buildPlatform.sdkName;
    final subs = <String, String>{
      'EXECUTABLE_NAME': PlistDefaults.executable,
      'PRODUCT_NAME': PlistDefaults.executable,
      'PRODUCT_MODULE_NAME': PlistDefaults.executable,
      'PRODUCT_BUNDLE_IDENTIFIER': bundleId,
      'DEVELOPMENT_LANGUAGE': 'en',
      'FLUTTER_BUILD_NAME': PlistDefaults.shortVersion,
      'FLUTTER_BUILD_NUMBER': PlistDefaults.bundleVersion,
      // Xcode expands these from the application target's build settings.
      // Without them, `ios/Runner/Info.plist` (which references them by
      // default) ships a literal "$(MARKETING_VERSION)" as the app version.
      'MARKETING_VERSION': _versions.shortVersion,
      'CURRENT_PROJECT_VERSION': _versions.bundleVersion,
    };

    // `receive_sharing_intent` and friends point the app's `AppGroupId` key
    // at `$(CUSTOM_GROUP_ID)`, which Xcode expands from the target's build
    // settings. The extension build already substitutes it; doing the same
    // here keeps both sides naming one container, instead of the app reading
    // back the literal `$(CUSTOM_GROUP_ID)` and finding nothing shared.
    final hostGroups = _hostAppGroups();
    if (hostGroups.isNotEmpty) {
      subs['CUSTOM_GROUP_ID'] = hostGroups.first;
    }

    final flutterConfigDirectory = runtime.host.paths.context.join(
      projectRoot,
      'ios',
      'Flutter',
    );
    final overrides = _buildVersionOverrides();
    subs.addAll(
      await runtime.xcconfigs.readDebugConfiguration(
        debugPath: runtime.host.paths.context.join(
          flutterConfigDirectory,
          'Debug.xcconfig',
        ),
        generatedPath: runtime.host.paths.context.join(
          flutterConfigDirectory,
          'Generated.xcconfig',
        ),
        sdk: selectedSdk,
        defaults: subs,
        overrides: overrides,
      ),
    );
    subs.addAll(overrides);

    return subs;
  }

  /// Settings pinned by explicit `--build-name` / `--build-number` flags.
  Map<String, String> _buildVersionOverrides() => {
    if (options.buildName case final String name) ...{
      'FLUTTER_BUILD_NAME': name,
      'MARKETING_VERSION': name,
    },
    if (options.buildNumber case final String number) ...{
      'FLUTTER_BUILD_NUMBER': number,
      'CURRENT_PROJECT_VERSION': number,
    },
  };
}
