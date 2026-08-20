import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/device/internal/embedded_extension.dart';
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/errors.dart';

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
abstract final class AppExtensionBuilder {
  /// Extensions xcross cannot build are skipped rather than failing the app
  /// build: an unbuildable extension costs the share-sheet entry, while a
  /// hard failure costs the whole app.
  static bool _isBuildable(IosAppExtension extension) {
    final hasSwift = extension.sources.any(
      (source) => source.endsWith('.swift') && File(source).existsSync(),
    );
    if (!hasSwift) {
      Log.logWarn(
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
  static Future<List<BuiltAppExtension>> buildAll({
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

    final darwin = DarwinSdk.current();
    if (darwin == null) {
      throw FlutterBuildError(
        'AppExtensionBuilder: Darwin SDK not found. '
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }

    final built = <BuiltAppExtension>[];
    for (final extension in buildable) {
      built.add(
        await Log.logStep(
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

  static Future<BuiltAppExtension> _build({
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
        .where((source) => File(source).existsSync())
        .toList();

    final bundleDir = p.join(outputDir, extension.bundleName);
    final staging = Directory(bundleDir);
    if (staging.existsSync()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    final target = extension.deploymentTarget == null
        ? deploymentTarget
        : IosDeploymentTarget(extension.deploymentTarget!);

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
    );
    await copyResources(extension: extension, bundleDir: bundleDir);

    return BuiltAppExtension(extension: extension, bundlePath: bundleDir);
  }

  /// Compile and link the extension executable with `swiftc`.
  static Future<void> _compile({
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
    final iosSdk = sdk.iPhoneOSSdk();
    final flutterSlice = p.join(flutterXcframework, 'ios-arm64');
    await Directory(moduleCache).create(recursive: true);

    final arguments = compileArguments(
      iosSdk: iosSdk,
      resourceDir: _swiftResourceDir(sdk),
      clangBuiltins: _clangBuiltins(_swiftResourceDir(sdk)),
      compilerRtIos: _compilerRtIos(sdk.bundle),
      sources: sources,
      outputPath: outputPath,
      deploymentTarget: deploymentTarget,
      flutterSlice: flutterSlice,
      moduleCache: moduleCache,
      moduleName: moduleName,
      ld64lld: await DarwinSdk.resolveLd64Lld(sdk),
      sdkVersion: _sdkVersion(iosSdk) ?? '26.5',
      pluginsLibrary: pluginsLibrary,
      pluginModulesDir: pluginModulesDir,
    );

    Log.logTrace('[swiftc] build app extension → $outputPath');
    await ProcessRunner.runChecked(
      swiftc,
      arguments,
      inheritStdio: Log.isVerbose,
      label: 'swiftc',
    );

    if (!File(outputPath).existsSync()) {
      throw FlutterBuildError(
        'AppExtensionBuilder: swiftc did not produce $outputPath',
      );
    }
    ProcessRunner.makeExecutable(outputPath);
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
    'ios',
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
  static Future<void> _writeInfoPlist({
    required IosAppExtension extension,
    required String bundleDir,
    required IosDeploymentTarget deploymentTarget,
    required IosBundleVersions versions,
  }) async {
    final source = extension.infoPlistPath;
    var xml = source != null && File(source).existsSync()
        ? await File(source).readAsString()
        : _fallbackInfoPlist;

    xml = expandExtensionVars(xml, extension: extension, versions: versions);
    // Storyboards can't be compiled off macOS, so an NSExtensionMainStoryboard
    // entry would point at a file that isn't in the bundle and the extension
    // would fail to launch. Swap it for the principal class the storyboard
    // names, which needs no ibtool.
    xml = replaceStoryboardWithPrincipalClass(xml, extension: extension);
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
    xml = AppExtensionPlist.setAppGroups(xml, extension.appGroups);

    await File(p.join(bundleDir, 'Info.plist')).writeAsString(xml);
  }

  /// Substitute the `$(VAR)` forms Xcode would have expanded for an extension
  /// target. `CUSTOM_GROUP_ID` is the convention `receive_sharing_intent` and
  /// friends use to inject the shared App Group into the extension plist.
  @visibleForTesting
  static String expandExtensionVars(
    String xml, {
    required IosAppExtension extension,
    IosBundleVersions versions = IosBundleVersions.fallback,
  }) {
    final substitutions = <String, String>{
      'PRODUCT_BUNDLE_IDENTIFIER': extension.bundleId,
      'PRODUCT_NAME': extension.name,
      'EXECUTABLE_NAME': extension.executableName,
      'DEVELOPMENT_LANGUAGE': 'en',
      'FLUTTER_BUILD_NAME': versions.shortVersion,
      'FLUTTER_BUILD_NUMBER': versions.bundleVersion,
      'MARKETING_VERSION': versions.shortVersion,
      'CURRENT_PROJECT_VERSION': versions.bundleVersion,
      if (extension.appGroups.isNotEmpty)
        'CUSTOM_GROUP_ID': extension.appGroups.first,
    };

    var result = xml;
    for (final entry in substitutions.entries) {
      result = result
          .replaceAll('\$(${entry.key})', entry.value)
          .replaceAll('\${${entry.key}}', entry.value);
    }
    return result;
  }

  /// Replace `NSExtensionMainStoryboard` with `NSExtensionPrincipalClass`.
  ///
  /// The storyboard's only job in a share/action extension is to instantiate
  /// the initial view controller, whose class it names via `customClass`.
  /// Naming that class directly through `NSExtensionPrincipalClass` is an
  /// equivalent, storyboard-free entry point, and the one Apple documents for
  /// programmatic extensions. The class is namespaced by the Swift module so
  /// the ObjC runtime can find it (`Share_Extension.ShareViewController`).
  @visibleForTesting
  static String replaceStoryboardWithPrincipalClass(
    String xml, {
    required IosAppExtension extension,
  }) {
    final storyboard = RegExp(
      r'\s*<key>\s*NSExtensionMainStoryboard\s*</key>\s*<string>([^<]*)</string>',
    ).firstMatch(xml);
    if (storyboard == null) return xml;

    final principalClass = _principalClassFor(
      extension,
      storyboardName: storyboard.group(1)!.trim(),
    );
    if (principalClass == null) {
      Log.logWarn(
        'App extension "${extension.name}" uses a storyboard that could not '
        'be resolved to a view controller class; it may not launch.',
      );
      return xml;
    }

    Log.logTrace(
      '${extension.name}: NSExtensionMainStoryboard → '
      'NSExtensionPrincipalClass $principalClass',
    );
    return xml.replaceRange(
      storyboard.start,
      storyboard.end,
      '\n\t\t<key>NSExtensionPrincipalClass</key>'
      '\n\t\t<string>$principalClass</string>',
    );
  }

  /// The `<module>.<class>` principal class for [extension], read from the
  /// storyboard's initial view controller `customClass`, falling back to the
  /// only view-controller-shaped Swift source file name.
  static String? _principalClassFor(
    IosAppExtension extension, {
    required String storyboardName,
  }) {
    final storyboard = extension.resources.firstWhere(
      (resource) =>
          p.basenameWithoutExtension(resource) == storyboardName &&
          resource.endsWith('.storyboard'),
      orElse: () => '',
    );

    String? className;
    if (storyboard.isNotEmpty && File(storyboard).existsSync()) {
      className = RegExp(
        'customClass="([^"]+)"',
      ).firstMatch(File(storyboard).readAsStringSync())?.group(1);
    }
    className ??= extension.sources
        .map(p.basenameWithoutExtension)
        .where((name) => name.endsWith('ViewController'))
        .firstOrNull;
    if (className == null) return null;

    // An @objc class keeps its bare ObjC name; a plain Swift class is
    // mangled as <module>.<class>, which is what Xcode writes here.
    return '${extension.moduleName}.$className';
  }

  /// Copy the extension's resources into the bundle.
  ///
  /// Storyboards and asset catalogs need `ibtool`/`actool`, which are macOS
  /// only, so uncompiled `.storyboard`/`.xcassets` inputs are skipped with a
  /// warning rather than shipped in a form iOS cannot read. A precompiled
  /// `.storyboardc`/`.car` sitting next to the source is used when present.
  @visibleForTesting
  static Future<void> copyResources({
    required IosAppExtension extension,
    required String bundleDir,
  }) async {
    for (final resource in extension.resources) {
      final name = p.basename(resource);
      // Localized resources keep their `<lang>.lproj` directory: it is how
      // iOS selects a language, and flattening it would also make every
      // language's copy of a file collide on one bundle-root name.
      final destination = p.joinAll([bundleDir, ?_lprojOf(resource), name]);
      if (name.endsWith('.storyboard')) {
        // Handled by replaceStoryboardWithPrincipalClass above.
        final compiled = '${p.withoutExtension(resource)}.storyboardc';
        if (Directory(compiled).existsSync()) {
          await _copyDirectory(
            compiled,
            p.join(p.dirname(destination), p.basename(compiled)),
          );
        } else {
          Log.logWarn(
            'Skipping "${extension.name}" storyboard $name: compiling '
            'storyboards needs ibtool (macOS only). The extension will use '
            'its principal class instead.',
          );
        }
        continue;
      }
      if (name.endsWith('.xcassets')) {
        Log.logWarn(
          'Skipping "${extension.name}" asset catalog $name: compiling asset '
          'catalogs needs actool (macOS only).',
        );
        continue;
      }

      if (Directory(resource).existsSync()) {
        await _copyDirectory(resource, destination);
      } else if (File(resource).existsSync()) {
        await Directory(p.dirname(destination)).create(recursive: true);
        await File(resource).copy(destination);
      }
    }
  }

  /// The `<lang>.lproj` directory [resource] sits in, or null when it is not
  /// a localized resource.
  static String? _lprojOf(String resource) {
    final parent = p.basename(p.dirname(resource));
    return parent.endsWith('.lproj') ? parent : null;
  }

  /// Locate `swiftc`, which the Swift toolchain puts on PATH.
  static Future<String> _resolveSwiftc() async {
    try {
      return await ProcessRunner.locateTool('swiftc');
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

  static String? _clangBuiltins(String resourceDir) {
    final candidate = p.join(resourceDir, 'clang', 'include');
    if (File(p.join(candidate, 'stdarg.h')).existsSync()) return candidate;
    return null;
  }

  /// `libclang_rt.ios.a` inside the Darwin SDK bundle's Xcode toolchain.
  static String? _compilerRtIos(String darwinSdkBundle) {
    final clang = Directory(
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
      final candidate = p.join(
        entry.path,
        'lib',
        'darwin',
        'libclang_rt.ios.a',
      );
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static String? _sdkVersion(String sdkPath) {
    final name = p.basenameWithoutExtension(sdkPath);
    if (!name.startsWith('iPhoneOS')) return null;
    final version = name.substring('iPhoneOS'.length);
    return version.isEmpty ? null : version;
  }

  static Future<void> _copyDirectory(String src, String dst) async {
    await Directory(dst).create(recursive: true);
    await for (final entity in Directory(src).list()) {
      final destPath = p.join(dst, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity.path, destPath);
      } else if (entity is File) {
        await entity.copy(destPath);
      }
    }
  }

  static const _fallbackInfoPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
''';
}

/// Minimal plist key forcing for `.appex` bundles.
abstract final class AppExtensionPlist {
  /// Set the keys iOS requires on an app extension, replacing existing ones.
  static String forceKeys(
    String xml, {
    required String bundleId,
    required String executableName,
    required String bundleName,
    required String minimumOsVersion,
    IosBundleVersions versions = IosBundleVersions.fallback,
  }) {
    var result = xml;
    final keys = <String, String>{
      'CFBundleIdentifier': bundleId,
      'CFBundleExecutable': executableName,
      'CFBundleName': bundleName,
      // installd rejects an appex without a non-empty CFBundleDisplayName
      // ("MissingBundleDisplayNameString"), even though apps may omit it.
      'CFBundleDisplayName': bundleName,
      'CFBundlePackageType': 'XPC!',
      'MinimumOSVersion': minimumOsVersion,
      'CFBundleInfoDictionaryVersion': '6.0',
      // iOS requires an extension's versions to match its host app's.
      'CFBundleShortVersionString': versions.shortVersion,
      'CFBundleVersion': versions.bundleVersion,
      'CFBundleDevelopmentRegion': 'en',
    };
    for (final entry in keys.entries) {
      result = setKey(result, entry.key, entry.value);
    }
    return result;
  }

  /// Record [appGroups] under [AppExtensionEntitlements.appGroupsInfoKey].
  static String setAppGroups(String xml, List<String> appGroups) {
    if (appGroups.isEmpty) return xml;
    const key = AppExtensionEntitlements.appGroupsInfoKey;
    final entries = appGroups
        .map((group) => '\n\t\t<string>$group</string>')
        .join();

    final existing = RegExp(
      '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<array>.*?</array>',
      dotAll: true,
    );
    final replacement = '<key>$key</key>\n\t<array>$entries\n\t</array>';
    if (existing.hasMatch(xml)) {
      return xml.replaceFirst(existing, replacement);
    }

    final dictIndex = xml.indexOf('<dict>');
    if (dictIndex == -1) return xml;
    final insertAt = dictIndex + '<dict>'.length;
    return '${xml.substring(0, insertAt)}\n\t$replacement'
        '${xml.substring(insertAt)}';
  }

  /// Replace `<key>[key]</key><string>…</string>`, inserting when absent.
  @visibleForTesting
  static String setKey(String xml, String key, String value) {
    final pattern = RegExp(
      '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<string>[^<]*</string>',
    );
    final replacement = '<key>$key</key>\n\t<string>$value</string>';
    if (pattern.hasMatch(xml)) {
      return xml.replaceFirst(pattern, replacement);
    }

    final dictIndex = xml.indexOf('<dict>');
    if (dictIndex == -1) return xml;
    final insertAt = dictIndex + '<dict>'.length;
    return '${xml.substring(0, insertAt)}\n\t$replacement'
        '${xml.substring(insertAt)}';
  }
}
