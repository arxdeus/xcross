import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/extensions/app_extension_plist.dart';
import 'package:xcross/src/shared/flutter/extensions/app_extension_resources.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';

/// A built `.appex` bundle staged outside the host app.
@immutable
final class BuiltAppExtension {
  const BuiltAppExtension({required this.extension, required this.bundlePath});

  final IosAppExtension extension;

  /// Absolute path to the staged `<Name>.appex` directory.
  final String bundlePath;
}

/// Compiles and assembles iOS app extensions (`.appex`) with the same
/// Xcode-free toolchain the Runner uses: `swiftc` from the Swift SDK plus the
/// Darwin SDK sysroot, linked by `ld64.lld`.
///
/// An extension is a nested bundle with its own executable, `Info.plist` and
/// resources, embedded at `<App>.app/PlugIns/<Name>.appex`. It links against
/// the same generated Flutter-plugins dylib as the host app (share extensions
/// commonly subclass a plugin's view controller, e.g.
/// `receive_sharing_intent`'s `RSIShareViewController`), resolving those at
/// runtime through `@executable_path/../../Frameworks`, which points back into
/// the host app's `Frameworks` directory.
final class AppExtensionBuilder<T extends PlatformHostInterface> {
  AppExtensionBuilder(this.runtime, this.resources);
  final FlutterBuildRuntime<T> runtime;
  final AppExtensionResources resources;

  /// Extensions xcross cannot build are skipped rather than failing the app
  /// build: an unbuildable extension costs the share-sheet entry, while a
  /// hard failure costs the whole app.
  bool _isBuildable(IosAppExtension extension) {
    final hasSwift = extension.sources.any(
      (source) =>
          source.endsWith('.swift') &&
          runtime.host.fileSystem.file(source).existsSync(),
    );
    if (!hasSwift) {
      runtime.runner.log.logWarn(
        'Skipping app extension "${extension.name}": it has no Swift sources '
        'to compile (xcross builds Swift app extensions only). The app will '
        'install without it.',
      );
    }
    return hasSwift;
  }

  /// Build every extension in [extensions], returning the staged bundles.
  ///
  /// [pluginsLibrary] and [pluginModulesDir] come from the aggregate Flutter
  /// plugins package and may be null for projects without SPM plugins.
  Future<List<BuiltAppExtension>> buildAll({
    required String projectRoot,
    required List<IosAppExtension> extensions,
    required IosDeploymentTarget deploymentTarget,
    required String outputDir,
    required String flutterXcframework,
    required IosBundleVersions versions,
    String? pluginsLibrary,
    String? pluginModulesDir,
  }) async {
    final buildable = extensions.where(_isBuildable).toList();
    if (buildable.isEmpty) return const [];

    final darwin = runtime.sdkRepository.current();
    if (darwin == null) {
      throw FlutterBuildError(
        'AppExtensionBuilder: Darwin SDK not found. '
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }

    final built = <BuiltAppExtension>[];
    for (final extension in buildable) {
      built.add(
        await runtime.runner.log.logStep(
          'Building ${extension.name}',
          () => _build(
            projectRoot: projectRoot,
            extension: extension,
            sdk: darwin,
            deploymentTarget: deploymentTarget,
            outputDir: outputDir,
            flutterXcframework: flutterXcframework,
            versions: versions,
            pluginsLibrary: pluginsLibrary,
            pluginModulesDir: pluginModulesDir,
          ),
        ),
      );
    }
    return built;
  }

  Future<BuiltAppExtension> _build({
    required String projectRoot,
    required IosAppExtension extension,
    required DarwinSdk sdk,
    required IosDeploymentTarget deploymentTarget,
    required String outputDir,
    required String flutterXcframework,
    required IosBundleVersions versions,
    String? pluginsLibrary,
    String? pluginModulesDir,
  }) async {
    // Non-Swift and missing sources are filtered by [_isBuildable].
    final sources = extension.sources
        .where((source) => source.endsWith('.swift'))
        .where((source) => runtime.host.fileSystem.file(source).existsSync())
        .toList();

    final bundleDir = p.join(outputDir, extension.bundleName);
    final staging = runtime.host.fileSystem.directory(bundleDir);
    if (staging.existsSync()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    final target = extension.deploymentTarget == null
        ? deploymentTarget
        : IosDeploymentTarget(
            extension.deploymentTarget!,
            platform: deploymentTarget.platform,
          );

    await _compile(
      sdk: sdk,
      sources: sources,
      outputPath: p.join(bundleDir, extension.executableName),
      deploymentTarget: target,
      flutterXcframework: flutterXcframework,
      pluginsLibrary: pluginsLibrary,
      pluginModulesDir: pluginModulesDir,
      moduleCache: p.join(outputDir, '.module-cache'),
      moduleName: extension.moduleName,
    );

    await _writeInfoPlist(
      extension: extension,
      bundleDir: bundleDir,
      deploymentTarget: target,
      versions: versions,
      sdkName: p
          .basenameWithoutExtension(
            runtime.sdkRepository.iosSdk(sdk, target: target.platform),
          )
          .toLowerCase(),
    );
    await resources.copyResources(extension: extension, bundleDir: bundleDir);

    return BuiltAppExtension(extension: extension, bundlePath: bundleDir);
  }

  /// Compile and link the extension executable with `swiftc`.
  Future<void> _compile({
    required DarwinSdk sdk,
    required List<String> sources,
    required String outputPath,
    required IosDeploymentTarget deploymentTarget,
    required String flutterXcframework,
    required String moduleCache,
    required String moduleName,
    String? pluginsLibrary,
    String? pluginModulesDir,
  }) async {
    final swiftc = await _resolveSwiftc();
    final iosSdk = runtime.sdkRepository.iosSdk(
      sdk,
      target: deploymentTarget.platform,
    );
    final flutterSlice = runtime.policy.selectEngineSlice(flutterXcframework);
    await runtime.host.fileSystem
        .directory(moduleCache)
        .create(recursive: true);

    final arguments = compileArguments(
      iosSdk: iosSdk,
      resourceDir: _swiftResourceDir(sdk),
      clangBuiltins: _clangBuiltins(_swiftResourceDir(sdk)),
      compilerRtIos: _compilerRtIos(
        sdk.bundle,
        runtimeLibrary: runtime.policy.sanitizerRuntimeLibrary,
      ),
      sources: sources,
      outputPath: outputPath,
      deploymentTarget: deploymentTarget,
      flutterSlice: flutterSlice,
      moduleCache: moduleCache,
      moduleName: moduleName,
      ld64lld: await runtime.toolchain.resolveLd64Lld(),
      sdkVersion: _sdkVersion(iosSdk) ?? '26.5',
      pluginsLibrary: pluginsLibrary,
      pluginModulesDir: pluginModulesDir,
    );

    runtime.runner.log.logTrace('[swiftc] build app extension → $outputPath');
    await runtime.runner.runChecked(
      swiftc,
      arguments,
      inheritStdio: runtime.runner.log.isVerbose,
      label: 'swiftc',
    );

    if (!runtime.host.fileSystem.file(outputPath).existsSync()) {
      throw FlutterBuildError(
        'AppExtensionBuilder: swiftc did not produce $outputPath',
      );
    }
    runtime.runner.makeExecutable(outputPath);
  }

  /// `swiftc` arguments for an app-extension executable.
  ///
  /// `-application-extension` is what makes the linker mark the Mach-O with
  /// `MH_APP_EXTENSION_SAFE` and reject non-extension-safe API, which iOS
  /// requires of any binary inside `PlugIns/`.
  @visibleForTesting
  static List<String> compileArguments({
    required String iosSdk,
    required String resourceDir,
    required List<String> sources,
    required String outputPath,
    required IosDeploymentTarget deploymentTarget,
    required String flutterSlice,
    required String moduleCache,
    required String ld64lld,
    required String sdkVersion,
    required String moduleName,
    String? clangBuiltins,
    String? compilerRtIos,
    String? pluginsLibrary,
    String? pluginModulesDir,
  }) => [
    '-sdk',
    iosSdk,
    '-target',
    deploymentTarget.buildTriple,
    // Without this swiftc infers the module name from the output file, and
    // falls back to `main` whenever that is not a valid Swift identifier —
    // which is exactly the case for a target named `Share Extension`. The
    // principal class would then really be `main.ShareViewController` while
    // the Info.plist names `Share_Extension.ShareViewController`, so iOS
    // fails to instantiate it and the extension shows a black screen.
    '-module-name',
    moduleName,
    // Without the Darwin SDK's own Swift resources the host toolchain tries
    // to rebuild the SDK's `Swift.swiftmodule` from its .swiftinterface and
    // fails ("no such module 'SwiftShims'" / SDK-compiler version mismatch).
    '-resource-dir',
    resourceDir,
    '-parse-as-library',
    '-application-extension',
    '-module-cache-path',
    moduleCache,
    '-use-ld=$ld64lld',
    '-Xfrontend',
    '-enable-cross-import-overlays',
    '-Xfrontend',
    '-disable-modules-validate-system-headers',
    '-F',
    flutterSlice,
    if (pluginModulesDir != null) ...['-I', pluginModulesDir],
    '-Xcc',
    '-isysroot',
    '-Xcc',
    iosSdk,
    if (clangBuiltins != null) ...['-Xcc', '-isystem', '-Xcc', clangBuiltins],
    '-Xcc',
    '-fapplication-extension',
    // An app extension has no main(): its entry point is _NSExtensionMain,
    // provided by the Foundation framework, which loads the principal class
    // named by NSExtensionPrincipalClass in the extension's Info.plist.
    '-Xlinker',
    '-e',
    '-Xlinker',
    '_NSExtensionMain',
    '-framework',
    'Foundation',
    '-framework',
    'UIKit',
    '-Xlinker',
    '-arch',
    '-Xlinker',
    'arm64',
    '-Xlinker',
    '-platform_version',
    '-Xlinker',
    deploymentTarget.linkerPlatform,
    '-Xlinker',
    deploymentTarget.version,
    '-Xlinker',
    sdkVersion,
    // The extension lives at <App>.app/PlugIns/<Name>.appex/<Name>, so the
    // host app's Frameworks directory (holding Flutter.framework and the
    // plugin dylibs it links) is two levels up from the executable.
    '-Xlinker',
    '-rpath',
    '-Xlinker',
    '@executable_path/../../Frameworks',
    // A non-Apple clang driving the Darwin link neither auto-links the
    // platform compiler-rt nor infers -arch/-platform_version; both are
    // passed explicitly here for the same reasons as in SwiftRunnerBuilder.
    if (compilerRtIos != null) ...['-Xlinker', compilerRtIos],
    if (pluginsLibrary != null) ...['-Xlinker', pluginsLibrary],
    ...sources,
    '-o',
    outputPath,
  ];

  /// Write the extension's `Info.plist`, forcing the identity keys iOS checks
  /// when loading a plugin: identifier, executable name, package type and the
  /// minimum OS version.
  Future<void> _writeInfoPlist({
    required IosAppExtension extension,
    required String bundleDir,
    required IosDeploymentTarget deploymentTarget,
    required IosBundleVersions versions,
    String? sdkName,
  }) async {
    final source = extension.infoPlistPath;
    var xml =
        source != null && runtime.host.fileSystem.file(source).existsSync()
        ? await runtime.host.fileSystem.file(source).readAsString()
        : AppExtensionPlist.fallback;

    xml = AppExtensionPlist.expandExtensionVars(
      xml,
      extension: extension,
      versions: versions,
    );
    // Storyboards can't be compiled off macOS, so an NSExtensionMainStoryboard
    // entry would point at a file that isn't in the bundle and the extension
    // would fail to launch. Swap it for the principal class the storyboard
    // names, which needs no ibtool.
    xml = resources.replaceStoryboardWithPrincipalClass(
      xml,
      extension: extension,
    );
    xml = AppExtensionPlist.forceKeys(
      xml,
      bundleId: extension.bundleId,
      executableName: extension.executableName,
      bundleName: extension.name,
      minimumOsVersion: deploymentTarget.version,
      versions: versions,
    );
    // Record the target's App Groups so the sign/install stage can provision
    // them without re-reading the Xcode project.
    xml = runtime.policy.transformPlist(xml, sdkName: sdkName);
    xml = AppExtensionPlist.setAppGroups(xml, extension.appGroups);

    await runtime.host.fileSystem
        .file(p.join(bundleDir, 'Info.plist'))
        .writeAsString(xml);
  }

  /// Substitute the `$(VAR)` forms Xcode would have expanded for an extension
  /// target. `CUSTOM_GROUP_ID` is the convention `receive_sharing_intent` and
  /// friends use to inject the shared App Group into the extension plist.
  /// Locate `swiftc`, which the Swift toolchain puts on PATH.
  Future<String> _resolveSwiftc() async {
    try {
      return await runtime.runner.locateTool('swiftc');
    } on Object {
      throw FlutterBuildError(
        'AppExtensionBuilder: swiftc not found on PATH. Building app '
        'extensions needs a Swift toolchain; run `xcross setup`.',
      );
    }
  }

  /// The Darwin SDK bundle's own Swift resource directory.
  static String _swiftResourceDir(DarwinSdk sdk) => p.join(
    sdk.bundle,
    'Developer',
    'Toolchains',
    'XcodeDefault.xctoolchain',
    'usr',
    'lib',
    'swift',
  );

  String? _clangBuiltins(String resourceDir) {
    final candidate = p.join(resourceDir, 'clang', 'include');
    if (runtime.host.fileSystem
        .file(p.join(candidate, 'stdarg.h'))
        .existsSync()) {
      return candidate;
    }
    return null;
  }

  /// `libclang_rt.ios.a` inside the Darwin SDK bundle's Xcode toolchain.
  String? _compilerRtIos(
    String darwinSdkBundle, {
    required String runtimeLibrary,
  }) {
    final clang = runtime.host.fileSystem.directory(
      p.join(
        darwinSdkBundle,
        'Developer',
        'Toolchains',
        'XcodeDefault.xctoolchain',
        'usr',
        'lib',
        'clang',
      ),
    );
    if (!clang.existsSync()) return null;
    final versions = clang.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final entry in versions) {
      final candidate = p.join(entry.path, 'lib', 'darwin', runtimeLibrary);
      if (runtime.host.fileSystem.file(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  static String? _sdkVersion(String sdkPath) {
    final name = p.basenameWithoutExtension(sdkPath);
    final match = RegExp(r'^iPhone(?:OS|Simulator)([0-9.]+)$').firstMatch(name);
    final version = match?.group(1) ?? '';
    return version.isEmpty ? null : version;
  }
}
