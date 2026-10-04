import 'package:cli_kit/cli_kit_shared.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/flutter/build/app_extension_builder.dart';
import 'package:xcross/src/flutter/build/info_plist.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/artifact/plist_mutations.dart';
import 'package:xcross/src/shared/flutter/extensions/app_extension_plist.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';

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
        pluginLibraries: linked.compiled.plugins?.dylibPaths ?? const [],
        nativeAssetFrameworks: linked.compiled.nativeAssets.frameworks,
        deploymentTarget: context.deploymentTarget,
        extensions: linked.extensions,
      );

  Future<String> _assembleAndPersistBundle({
    required String appFramework,
    required String xcframework,
    required String runnerBinary,
    required String sdkName,
    required List<String> pluginLibraries,
    required List<String> nativeAssetFrameworks,
    required IosDeploymentTarget deploymentTarget,
    required List<BuiltAppExtension> extensions,
  }) async {
    // Stage in a temp dir so the destination is only touched once everything
    // is in place.
    final tmp = await runtime.host.fileSystem
        .directory(runtime.host.paths.temporaryRoot)
        .createTemp('${appName}_app_bundle-');

    await _stageBundle(
      bundleDir: tmp.path,
      appFramework: appFramework,
      flutterFramework: runtime.host.paths.context.join(
        runtime.policy.selectEngineSlice(xcframework),
        'Flutter.framework',
      ),
      runnerBinary: runnerBinary,
      sdkName: sdkName,
      pluginLibraries: pluginLibraries,
      nativeAssetFrameworks: nativeAssetFrameworks,
      deploymentTarget: deploymentTarget,
      extensions: extensions,
    );

    final dest = runtime.host.paths.context.join(
      outputDirectory,
      '$appName.app',
    );
    final destDir = runtime.host.fileSystem.directory(dest);
    if (destDir.existsSync()) {
      await destDir.delete(recursive: true);
    }
    await runtime.host.fileSystem
        .directory(runtime.host.paths.context.dirname(dest))
        .create(recursive: true);
    await runtime.directoryCopier.copy(tmp.path, dest);
    await tmp.delete(recursive: true);

    return dest;
  }

  /// Lay out the `.app` contents under [bundleDir]: the Runner executable,
  /// the embedded frameworks and plugin dylibs, storyboards, and `Info.plist`.
  Future<void> _stageBundle({
    required String bundleDir,
    required String appFramework,
    required String flutterFramework,
    required String runnerBinary,
    required String sdkName,
    required List<String> pluginLibraries,
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
    await runtime.frameworks.copyPluginLibraries(
      pluginLibraries,
      frameworksDir,
    );
    await runtime.frameworks.copyNativeAssetFrameworks(
      nativeAssetFrameworks,
      frameworksDir,
    );

    await _embedAppExtensions(bundleDir, extensions);
    await runtime.resources.stage(
      projectRoot: projectRoot,
      bundleDir: bundleDir,
    );
    await _writeInfoPlist(
      bundleDir,
      deploymentTarget: deploymentTarget,
      sdkName: sdkName,
    );
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
  /// substitution, mandatory iOS keys, storyboard stripping, and ObjC class
  /// name normalization.
  Future<void> _writeInfoPlist(
    String bundleDir, {
    required IosDeploymentTarget deploymentTarget,
    required String sdkName,
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
    );
    plistXml = runtime.policy.transformPlist(plistXml, sdkName: sdkName);
    plistXml = InfoPlist.applyDebugVmServiceDiscovery(plistXml);
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
    if (plistFile.existsSync()) return plistFile.readAsString();
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
