import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/build/compose_packer.dart';
import 'package:xcross/src/build/compose_setup.dart';
import 'package:xcross/src/build/ios_app_config.dart';
import 'package:xcross/src/build/kmp_project.dart';
import 'package:xcross/src/models/cli/pack_result.dart';
import 'package:xcross/src/models/compose/compose_options.dart';
import 'package:xcross/src/models/config/pack_schema.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/xtool/darwin_sdk.dart';

// ── Public entry point ────────────────────────────────────────────────────────

/// Build a Kotlin Multiplatform iOS `.app` for the project in the current
/// directory using [ComposePacker] (pure Dart — no shell pipeline.sh).
///
/// Mirrors `ComposePackOperation.run()` from ComposeCommand.swift.
///
/// Config wired into ComposePacker:
///   kmpProjectRoot — Directory.current.path
///   sdkBundle      — DarwinSdk.bundle
///   iPhoneSdk      — DarwinSdk.iPhoneOSSdk()
///   ld64lld        — env XCROSS_LD64LLD (x86_64, amd64 image) ?? DarwinSdk.ld64lld
///   appName        — derived from bundleId last segment (or IosAppConfig for swiftApp)
///   bundleId       — from xtool.yml (or IosAppConfig for swiftApp, or default)
///   lxKn           — Platform.environment['LX_KN'] ?? default
///   javaHome       — Platform.environment['JAVA_HOME'] (native JDK)
///   module fields  — from detectKmpFramework() (baseName, moduleName, etc.)
///   iosAppConfig   — from IosAppConfig.load() (xcconfig bundleId/productName)
///
/// [requireRunnableApp]: when `true`, a [KmpEntryKind.frameworkOnly] project
/// causes an early [XcrossError] with a clear message. Set by `compose run`
/// and any pipeline that needs a full `.app` (not just a framework).
/// [KmpEntryKind.swiftApp] projects are NOT blocked — they produce a real .app.
Future<PackResult> composePack({
  required ComposeOptions options,
  bool requireRunnableApp = false,
}) async {
  final projectRoot = Directory.current.path;

  // 0. Verify the host toolchain (JDK, ld64.lld, konanc + ios_arm64, gradle)
  //    before any work.
  final toolchain = await ensureComposeToolchain(projectRoot: projectRoot);

  // 1. Detect KMP module structure.
  final module = detectKmpFramework(projectRoot);
  logStatus(
    '[compose] detected module: ${module.moduleName}  '
    'baseName: ${module.baseName}  kind: ${module.entryKind}',
  );

  // S4 guard: ONLY true frameworkOnly blocks run/ipa.
  // swiftApp and runnableApp both produce a full .app and are allowed.
  if (module.entryKind == KmpEntryKind.frameworkOnly &&
      (requireRunnableApp || options.ipa)) {
    final expectedFwPath = p.join(
        projectRoot, 'build', 'xtool-ios', '${module.baseName}.framework');
    throw XcrossError(
      'This is a framework-only KMP module '
      '(module ${module.moduleName}). '
      'Its runnable app requires a Swift/ObjC host that xcross cannot build '
      'on Linux for this project. `xcross compose build` produces the '
      'framework at $expectedFwPath; `compose run` and `--ipa` are not '
      'supported for this project.',
    );
  }

  // 2. Load xtool.yml; warn + use default if absent.
  final PackSchema schema;
  final configPath = p.join(projectRoot, 'xtool.yml');
  final configExists = File(configPath).existsSync();
  if (configExists) {
    schema = await PackSchema.fromFile(configPath);
  } else {
    schema = PackSchema.defaultSchema();
    logWarn(
      "Could not locate configuration file 'xtool.yml'. Using default "
      "configuration with 'com.example' organization ID.",
    );
  }

  // 3. Load IosAppConfig from iosApp/Configuration/Config.xcconfig (optional).
  //    For swiftApp projects this is the primary source of bundleId/appName;
  //    for runnableApp/frameworkOnly it provides version strings if present.
  final iosAppConfig = IosAppConfig.load(projectRoot);

  // 4. Derive bundle ID and app name.
  //    swiftApp: prefer xcconfig values (which Xcode would use at build time).
  //    Other kinds: derive from xtool.yml / bundle-id logic as before.
  final String bundleId;
  final String appName;
  if (module.entryKind == KmpEntryKind.swiftApp &&
      iosAppConfig != null &&
      iosAppConfig.bundleId.isNotEmpty) {
    bundleId = iosAppConfig.bundleId;
    appName = iosAppConfig.productName.isNotEmpty
        ? iosAppConfig.productName
        : _deriveAppName(iosAppConfig.bundleId);
    logStatus(
      '[compose] swiftApp identity ← Config.xcconfig: '
      '$appName ($bundleId)',
    );
  } else {
    bundleId =
        schema.idSpecifier.formBundleId(schema.product ?? 'compose');
    appName = _deriveAppName(bundleId);
  }

  // 5. Resolve the Darwin SDK — bundle + iPhone SDK + ld64.lld required.
  final darwin = DarwinSdk.current();
  if (darwin == null) {
    throw XcrossError(
      'compose: Darwin SDK not found.\n'
      "Install xtool's Darwin SDK with `xtool sdk install <Xcode.xip|Xcode.app>`.",
    );
  }

  // 6. Delete any prior bundle before packing.
  final outDir = p.join(projectRoot, 'build', 'xtool-ios');
  final priorApp = Directory(p.join(outDir, '$appName.app'));
  final priorFramework =
      Directory(p.join(outDir, '${module.baseName}.framework'));
  if (priorApp.existsSync()) await priorApp.delete(recursive: true);
  if (priorFramework.existsSync()) {
    await priorFramework.delete(recursive: true);
  }

  logStatus(
    '[compose] building $appName ($bundleId) '
    '— ${options.configuration.label}',
  );

  // 7. Build with ComposePacker (pure Dart; all stages).
  final packer = ComposePacker(
    kmpProjectRoot: projectRoot,
    sdkBundle: darwin.bundle,
    iPhoneSdk: darwin.iPhoneOSSdk(),
    ld64lld: toolchain.ld64lld ??
        Platform.environment['XCROSS_LD64LLD'] ??
        darwin.ld64lld,
    appName: appName,
    bundleId: bundleId,
    lxKn: toolchain.lxKn,
    javaHome: toolchain.javaHome,
    konanDataDir: toolchain.konanDataDir,
    // Module fields from detectKmpFramework().
    baseName: module.baseName,
    moduleName: module.moduleName,
    modulePath: module.modulePath,
    entryKind: module.entryKind,
    entryClass: module.entryClass,
    entrySelector: module.entrySelector,
    // swiftApp fields.
    swiftSources: module.swiftSources,
    swiftAppDir: module.swiftAppDir,
    // Parsed xcconfig (version strings + bundleId for Info.plist synthesis).
    iosAppConfig: iosAppConfig,
    // Optional user-supplied complete Info.plist (B1 fix).
    infoPath: schema.infoPath,
  );

  final outputPath = await packer.pack();

  // 8. Verify the packer produced the expected output.
  final outputExists = Directory(outputPath).existsSync();
  if (!outputExists) {
    throw XcrossError(
      'compose: ComposePacker exited successfully but $outputPath was not found.',
    );
  }

  return PackResult(outputPath, bundleId);
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Derive the iOS app bundle name from a bundle identifier.
///
/// Rule (mirrors xtool's ComposePacker.appName):
///   last segment of bundleId → uppercase first letter → append "App"
///
/// Examples:
///   `com.example.xtoolKmpPoc` → `XtoolKmpPocApp`
///   `com.example.fooBar`      → `FooBarApp`
///   (empty or no segments)    → `ComposeApp`
String _deriveAppName(String bundleId) {
  final last = bundleId.split('.').lastOrNull ?? '';
  if (last.isEmpty) return 'ComposeApp';
  final capitalized = last[0].toUpperCase() + last.substring(1);
  return '${capitalized}App';
}
