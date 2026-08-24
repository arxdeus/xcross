import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/app_extension_builder.dart';
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/flutter/build/info_plist.dart';
import 'package:xcross/src/flutter/build/internal/runner_binary.dart';
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/flutter/models/pubspec_info.dart';
import 'package:xcross/src/package_config_resolver.dart';

/// Builds a Flutter iOS `.app` bundle using Dart and xcross's cross-platform
/// toolchain. Does NOT call `xcrun`.
///
/// Pipeline (debug/JIT only — xcross does not support release/AOT):
///   1. Resolve `FLUTTER_ROOT` and run `flutter pub get`.
///   2. Build `App.framework` via [FlutterDebugBundler] (frontend_server
///      one-shot + clang stub dylib + ld64.lld from PATH).
///   3. Discover iOS plugins and build the aggregate Swift Package Manager
///      plugins library via [GeneratedPluginsPackage], if any exist.
///   4. Compile the ObjC Runner shim via [RunnerShim], linking in the
///      plugins library when present.
///   5. Assemble the `.app` bundle and write `Info.plist`.
final class FlutterPacker {
  final String projectRoot;
  final String bundleId;
  final FlutterBuildOptions options;

  /// App name read from `pubspec.yaml` `name:` key.
  final String appName;

  FlutterPacker({
    required this.projectRoot,
    required this.bundleId,
    required this.options,
  }) : appName = PubspecInfo.loadSync(projectRoot).name,
       _versions = IosBundleVersions.resolve(
         projectRoot,
         buildName: options.buildName,
         buildNumber: options.buildNumber,
       );

  /// Versions the app and every embedded extension must agree on.
  final IosBundleVersions _versions;

  /// Build the Flutter iOS app.
  /// Returns path to `<projectRoot>/build/xcross-ios/<appName>.app`.
  Future<String> pack() async {
    final flutterRoot = await resolveFlutterRoot(projectRoot: projectRoot);
    Log.logTrace('Flutter SDK: $flutterRoot');

    if (options.pub) {
      await _runFlutterPubGet(flutterRoot);
    } else {
      Log.logTrace('skipping flutter pub get (--no-pub)');
    }

    if (options.flavor != null) {
      Log.logTrace('building flavor "${options.flavor}"');
    }

    final deploymentTarget = IosDeploymentTarget.resolve(projectRoot);
    Log.logTrace('iOS deployment target: ${deploymentTarget.version}');

    final appFramework = await _buildAppFramework(
      flutterRoot,
      deploymentTarget: deploymentTarget,
    );
    final pluginsBuild = await _buildPlugins(
      flutterRoot,
      deploymentTarget: deploymentTarget,
      verbose: Log.isVerbose,
    );
    final runnerResult = await _buildRunnerBinary(
      flutterRoot,
      deploymentTarget: deploymentTarget,
      pluginsLibrary: pluginsBuild?.libraryPath,
      verbose: Log.isVerbose,
    );

    final extensions = await _buildAppExtensions(
      deploymentTarget: deploymentTarget,
      flutterXcframework: runnerResult.xcframework,
      pluginsBuild: pluginsBuild,
    );

    return _assembleAndPersistBundle(
      appFramework: appFramework,
      xcframework: runnerResult.xcframework,
      runnerBinary: runnerResult.runnerBinary,
      pluginLibraries: pluginsBuild?.dylibPaths ?? const [],
      deploymentTarget: deploymentTarget,
      extensions: extensions,
    );
  }

  /// Resolve the Flutter SDK root using, in order:
  ///   1. `FLUTTER_ROOT` environment variable.
  ///   2. `<projectRoot>/.fvm/flutter_sdk` symlink (fvm).
  ///   3. `which flutter` → parent of `bin/`.
  static Future<String> resolveFlutterRoot({
    required String projectRoot,
  }) async {
    final envRoot = Platform.environment['FLUTTER_ROOT'];
    if (envRoot != null && envRoot.isNotEmpty) return envRoot;

    final fvmLink = p.join(projectRoot, '.fvm', 'flutter_sdk');
    final fvmLinkExists =
        Directory(fvmLink).existsSync() || Link(fvmLink).existsSync();
    if (fvmLinkExists) {
      return Link(fvmLink).resolveSymbolicLinksSync();
    }

    final flutter = await ProcessRunner.locateTool('flutter');
    // The `flutter` script lives at <root>/bin/flutter.
    return p.dirname(p.dirname(File(flutter).resolveSymbolicLinksSync()));
  }

  /// Run `flutter pub get`. Tolerates failures when `package_config.json`
  /// already exists (container builds with ephemeral pub caches).
  Future<void> _runFlutterPubGet(String flutterRoot) {
    return Log.logStep('Resolving dependencies', () async {
      try {
        await ProcessRunner.runChecked(
          p.join(
            flutterRoot,
            'bin',
            ProcessRunner.hostExecutableName(
              'flutter',
              windowsExtension: '.bat',
            ),
          ),
          ['pub', 'get'],
          workingDirectory: projectRoot,
          // `pub get` is non-interactive; inheriting fd1 would shred the
          // spinner, so only inherit when verbose (no spinner then).
          inheritStdio: Log.isVerbose,
          label: 'flutter',
        );
      } on FlutterBuildError {
        final packageConfig = await PackageConfigResolver.find(projectRoot);
        final packageConfigExists = packageConfig != null;
        if (packageConfigExists) {
          Log.logWarn(
            'Ignoring flutter pub get error because '
            'package_config.json exists.',
          );
          return;
        }
        rethrow;
      }
    });
  }

  /// Build `App.framework` via [FlutterDebugBundler].
  /// Returns the framework directory path.
  Future<String> _buildAppFramework(
    String flutterRoot, {
    required IosDeploymentTarget deploymentTarget,
  }) async {
    final assembleOut = p.join(projectRoot, 'build', 'xcross-flutter-debug');
    final assembleDir = Directory(assembleOut);
    if (assembleDir.existsSync()) await assembleDir.delete(recursive: true);
    await assembleDir.create(recursive: true);

    return FlutterDebugBundler(
      projectRoot: projectRoot,
      flutterRoot: flutterRoot,
      outputDir: assembleOut,
      deploymentTarget: deploymentTarget,
      entrypoint: options.target,
      dartDefines: options.dartDefines,
      flavor: options.flavor,
    ).build();
  }

  /// Discover the project's iOS plugins and build the aggregate Swift
  /// Package Manager plugins library, if any exist.
  ///
  /// Returns the built dylibs, or null when there's nothing to build — no
  /// plugins at all, or only CocoaPods-only ones xcross doesn't support (a
  /// warning is logged for those; matching Flutter's own tool, this doesn't
  /// fail the build).
  Future<GeneratedPluginsBuildResult?> _buildPlugins(
    String flutterRoot, {
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
  }) async {
    final plugins = await PluginDiscovery.discover(projectRoot);
    final spmPlugins = <IosPlugin>[];
    for (final plugin in plugins) {
      final dir = plugin.platformDirectoryName;
      if (plugin.usesSwiftPackageManager) {
        spmPlugins.add(plugin);
      } else if (plugin.usesCocoaPods) {
        Log.logWarn(
          'Plugin "${plugin.name}" only ships a CocoaPods podspec '
          '(no $dir/${plugin.name}/Package.swift); its native iOS code will '
          'not be included. xcross only supports Swift Package Manager '
          'plugins.',
        );
      } else if (plugin.declaresNativeIosCode) {
        // The plugin's pubspec claims a native iOS pluginClass, but neither a
        // Package.swift nor a podspec turned up where they were looked for.
        // Staying silent here is what made a dropped plugin present as a black
        // screen: the app launches, then the first method channel call to the
        // missing implementation never returns.
        Log.logWarn(
          'Plugin "${plugin.name}" declares native iOS code but no '
          '$dir/${plugin.name}/Package.swift or $dir/${plugin.name}.podspec '
          'was found under ${plugin.packageRoot}; its plugin channels will '
          'not respond at runtime.',
        );
      }
    }
    if (spmPlugins.isEmpty) return null;

    final xcframework = IosEngineCache(
      flutterRoot: flutterRoot,
    ).flutterXcframework;

    return GeneratedPluginsPackage.build(
      projectRoot: projectRoot,
      plugins: spmPlugins,
      flutterXcframework: xcframework,
      outputDir: p.join(projectRoot, 'build', 'xcross-flutter-plugins'),
      deploymentTarget: deploymentTarget,
      verbose: verbose,
    );
  }

  /// Build the project's iOS app extensions (share/action extensions), if any.
  ///
  /// Extensions whose bundle id is not nested under the host app's are
  /// skipped with a warning: iOS refuses to install those, and dropping one
  /// is better than failing an otherwise valid app build.
  Future<List<BuiltAppExtension>> _buildAppExtensions({
    required IosDeploymentTarget deploymentTarget,
    required String flutterXcframework,
    GeneratedPluginsBuildResult? pluginsBuild,
  }) async {
    final discovered = IosAppExtensions.discover(projectRoot);
    if (discovered.isEmpty) return const [];

    final buildable = <IosAppExtension>[];
    for (final extension in discovered) {
      if (extension.suffixUnder(bundleId) == null) {
        Log.logWarn(
          'Skipping app extension "${extension.name}": its bundle id '
          '${extension.bundleId} is not nested under the app id $bundleId.',
        );
        continue;
      }
      buildable.add(extension);
    }

    return AppExtensionBuilder.buildAll(
      projectRoot: projectRoot,
      extensions: buildable,
      deploymentTarget: deploymentTarget,
      outputDir: p.join(projectRoot, 'build', 'xcross-flutter-extensions'),
      versions: _versions,
      flutterXcframework: flutterXcframework,
      pluginsLibrary: pluginsBuild?.libraryPath,
      pluginModulesDir: pluginsBuild?.modulesDir,
    );
  }

  /// Compile the ObjC Runner shim and return both the xcframework path and the
  /// linked Runner binary path.
  Future<RunnerBinary> _buildRunnerBinary(
    String flutterRoot, {
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
    String? pluginsLibrary,
  }) async {
    final xcframework = IosEngineCache(
      flutterRoot: flutterRoot,
    ).flutterXcframework;

    final darwin = DarwinSdk.current();
    if (darwin == null) {
      throw FlutterBuildError(
        'FlutterPacker: Darwin SDK not found. '
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }

    final runnerBinary = await RunnerShim.buildRunnerBinary(
      projectRoot: projectRoot,
      sdk: darwin,
      flutterXcframework: xcframework,
      outputDir: p.join(projectRoot, 'build', 'xcross-flutter-runner-bin'),
      deploymentTarget: deploymentTarget,
      pluginsLibrary: pluginsLibrary,
      verbose: verbose,
    );

    return RunnerBinary(xcframework: xcframework, runnerBinary: runnerBinary);
  }

  /// Stage the bundle in a temp directory, then move it to
  /// `build/xcross-ios/<appName>.app`.
  Future<String> _assembleAndPersistBundle({
    required String appFramework,
    required String xcframework,
    required String runnerBinary,
    required List<String> pluginLibraries,
    required IosDeploymentTarget deploymentTarget,
    required List<BuiltAppExtension> extensions,
  }) async {
    // Stage in a temp dir so the destination is only touched once everything
    // is in place.
    final tmp = await Directory.systemTemp.createTemp('${appName}_app_bundle-');

    await _stageBundle(
      bundleDir: tmp.path,
      appFramework: appFramework,
      flutterFramework: p.join(xcframework, 'ios-arm64', 'Flutter.framework'),
      runnerBinary: runnerBinary,
      pluginLibraries: pluginLibraries,
      deploymentTarget: deploymentTarget,
      extensions: extensions,
    );

    final dest = p.join(projectRoot, 'build', 'xcross-ios', '$appName.app');
    final destDir = Directory(dest);
    if (destDir.existsSync()) {
      await destDir.delete(recursive: true);
    }
    await Directory(p.dirname(dest)).create(recursive: true);
    await _copyDirectory(tmp.path, dest);
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
    required List<String> pluginLibraries,
    required IosDeploymentTarget deploymentTarget,
    required List<BuiltAppExtension> extensions,
  }) async {
    final frameworksDir = p.join(bundleDir, 'Frameworks');
    await Directory(frameworksDir).create(recursive: true);

    final runnerDest = p.join(bundleDir, 'Runner');
    await File(runnerBinary).copy(runnerDest);
    ProcessRunner.makeExecutable(runnerDest);

    await _copyDirectory(
      flutterFramework,
      p.join(frameworksDir, 'Flutter.framework'),
    );
    await _copyDirectory(appFramework, p.join(frameworksDir, 'App.framework'));
    await copyPluginLibraries(pluginLibraries, frameworksDir);

    await _embedAppExtensions(bundleDir, extensions);
    await _copyOptionalRunnerResources(bundleDir);
    await _writeInfoPlist(bundleDir, deploymentTarget: deploymentTarget);
  }

  /// Copy each built `.appex` into the app's `PlugIns` directory, the only
  /// location iOS looks for embedded app extensions.
  static Future<void> _embedAppExtensions(
    String bundleDir,
    List<BuiltAppExtension> extensions,
  ) async {
    if (extensions.isEmpty) return;
    final plugInsDir = p.join(bundleDir, 'PlugIns');
    await Directory(plugInsDir).create(recursive: true);
    for (final extension in extensions) {
      await _copyDirectory(
        extension.bundlePath,
        p.join(plugInsDir, extension.extension.bundleName),
      );
    }
  }

  /// Copies every SwiftPM-produced dylib into the app's Frameworks directory.
  @visibleForTesting
  static Future<void> copyPluginLibraries(
    Iterable<String> pluginLibraries,
    String frameworksDir,
  ) async {
    for (final library in pluginLibraries) {
      await File(library).copy(p.join(frameworksDir, p.basename(library)));
    }
  }

  /// Copy compiled storyboards from `ios/Runner/` into the bundle, if present.
  Future<void> _copyOptionalRunnerResources(String bundleDir) async {
    final runnerDir = p.join(projectRoot, 'ios', 'Runner');
    const storyboards = [
      'Base.lproj/LaunchScreen.storyboardc',
      'Base.lproj/Main.storyboardc',
    ];
    for (final rel in storyboards) {
      final src = p.join(runnerDir, rel);
      if (!Directory(src).existsSync()) continue;
      final dst = p.join(bundleDir, p.basename(src));
      final dstDir = Directory(dst);
      if (dstDir.existsSync()) {
        await dstDir.delete(recursive: true);
      }
      await _copyDirectory(src, dst);
    }
  }

  /// Generate and write `Info.plist` into [bundleDir] with `$(VAR)`
  /// substitution, mandatory iOS keys, storyboard stripping, and ObjC class
  /// name normalization.
  Future<void> _writeInfoPlist(
    String bundleDir, {
    required IosDeploymentTarget deploymentTarget,
  }) async {
    var plistXml = await _loadPlistTemplate();

    // ORDER MATTERS: vars must be expanded before forcing keys so that forced
    // keys see already-substituted values from the template, and before
    // storyboard stripping so $(VAR)-valued storyboard names are resolved
    // before the .storyboardc filesystem probe.
    plistXml = InfoPlist.expandVars(plistXml, await _buildSubstitutionMap());
    plistXml = InfoPlist.applyIosRequiredKeys(
      plistXml,
      bundleId: bundleId,
      deploymentTarget: deploymentTarget,
    );
    plistXml = InfoPlist.stripUnsatisfiableStoryboards(plistXml, bundleDir);
    plistXml = InfoPlist.normalizeObjCClassNames(plistXml);
    // Carry the app's own App Groups forward so the sign/install stage can
    // provision them alongside its extensions'.
    plistXml = AppExtensionPlist.setAppGroups(plistXml, _hostAppGroups());

    await File(p.join(bundleDir, 'Info.plist')).writeAsString(plistXml);
  }

  /// App Groups declared by the application target's entitlements file.
  List<String> _hostAppGroups() {
    final extensionGroups = IosAppExtensions.applicationEntitlements(
      projectRoot,
    );
    return IosAppExtensions.readAppGroups(extensionGroups);
  }

  /// Read `ios/Runner/Info.plist`, falling back to [InfoPlist.fallback].
  Future<String> _loadPlistTemplate() async {
    final plistFile = File(p.join(projectRoot, 'ios', 'Runner', 'Info.plist'));
    if (plistFile.existsSync()) return plistFile.readAsString();
    return InfoPlist.fallback;
  }

  /// Build the `$(VAR)` substitution map.
  ///
  /// Precedence (lowest → highest):
  ///   1. Hard-coded defaults (`1.0.0` / `1`).
  ///   2. `Generated.xcconfig` values from `flutter build` tooling.
  ///   3. Explicit `--build-name` / `--build-number` CLI flags.
  Future<Map<String, String>> _buildSubstitutionMap() async {
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

    final xcconfigFile = File(
      p.join(projectRoot, 'ios', 'Flutter', 'Generated.xcconfig'),
    );
    if (xcconfigFile.existsSync()) {
      subs.addAll(InfoPlist.parseXcconfig(await xcconfigFile.readAsString()));
    }

    if (options.buildName != null) {
      subs['FLUTTER_BUILD_NAME'] = options.buildName!;
      subs['MARKETING_VERSION'] = options.buildName!;
    }
    if (options.buildNumber != null) {
      subs['FLUTTER_BUILD_NUMBER'] = options.buildNumber!;
      subs['CURRENT_PROJECT_VERSION'] = options.buildNumber!;
    }

    return subs;
  }

  /// Recursively copy [src] to [dst], preserving symlinks.
  static Future<void> _copyDirectory(String src, String dst) async {
    await Directory(dst).create(recursive: true);
    await for (final entity in Directory(src).list()) {
      final name = p.basename(entity.path);
      final destPath = p.join(dst, name);
      if (entity is Directory) {
        await _copyDirectory(entity.path, destPath);
      } else if (entity is File) {
        await entity.copy(destPath);
      } else if (entity is Link) {
        final link = Link(destPath);
        if (link.existsSync()) await link.delete();
        await link.create(await entity.target());
      }
    }
  }
}
