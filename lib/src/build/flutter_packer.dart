import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:xcross/src/build/flutter_debug_bundler.dart';
import 'package:xcross/src/build/info_plist.dart';
import 'package:xcross/src/build/ios_engine_cache.dart';
import 'package:xcross/src/build/runner_shim.dart';
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/models/config/pack_schema.dart';
import 'package:xcross/src/models/config/pubspec_info.dart';
import 'package:xcross/src/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/xtool/darwin_sdk.dart';

/// Builds a Flutter iOS `.app` bundle using dart + xtool's cross-platform
/// toolchain. Does NOT call `xcrun`.
///
/// Pipeline (debug/JIT only — xcross does not support release/AOT):
///   1. Resolve `FLUTTER_ROOT` and run `flutter pub get`.
///   2. Build `App.framework` via [FlutterDebugBundler] (frontend_server
///      one-shot + clang stub dylib + xtool's ld64.lld).
///   3. Compile the ObjC Runner shim via [RunnerShim].
///   4. Assemble the `.app` bundle and write `Info.plist`.
class FlutterPacker {
  final String projectRoot;
  final PackSchema schema;
  final FlutterBuildOptions options;

  /// App name read from `pubspec.yaml` `name:` key.
  final String appName;

  FlutterPacker({
    required this.projectRoot,
    required this.schema,
    required this.options,
  }) : appName = PubspecInfo.loadSync(projectRoot).name;

  /// Build the Flutter iOS app.
  /// Returns path to `<projectRoot>/build/xtool-ios/<appName>.app`.
  Future<String> pack() async {
    final flutterRoot = await resolveFlutterRoot(projectRoot: projectRoot);
    logStatus('[xcross] Flutter SDK: $flutterRoot');

    if (options.pub) {
      await _runFlutterPubGet(flutterRoot);
    } else {
      logStatus('[xcross] skipping flutter pub get (--no-pub).');
    }

    if (options.flavor != null) {
      logStatus('[xcross] building flavor "${options.flavor}"...');
    }

    final appFramework = await _buildAppFramework(flutterRoot);
    final (:xcframework, :runnerBinary) = await _buildRunnerBinary(flutterRoot);

    return _assembleAndPersistBundle(
      appFramework: appFramework,
      xcframework: xcframework,
      runnerBinary: runnerBinary,
    );
  }

  /// Resolve the Flutter SDK root using, in order:
  ///   1. `FLUTTER_ROOT` environment variable.
  ///   2. `<projectRoot>/.fvm/flutter_sdk` symlink (fvm).
  ///   3. `which flutter` → parent of `bin/`.
  static Future<String> resolveFlutterRoot(
      {required String projectRoot}) async {
    final envRoot = Platform.environment['FLUTTER_ROOT'];
    if (envRoot != null && envRoot.isNotEmpty) return envRoot;

    final fvmLink = p.join(projectRoot, '.fvm', 'flutter_sdk');
    if (Directory(fvmLink).existsSync() || Link(fvmLink).existsSync()) {
      return Link(fvmLink).resolveSymbolicLinksSync();
    }

    final flutter = await locateTool('flutter');
    // The `flutter` script lives at <root>/bin/flutter.
    return p.dirname(p.dirname(File(flutter).resolveSymbolicLinksSync()));
  }

  /// Run `flutter pub get`. Tolerates failures when `package_config.json`
  /// already exists (container builds with ephemeral pub caches).
  Future<void> _runFlutterPubGet(String flutterRoot) async {
    final packageConfig =
        p.join(projectRoot, '.dart_tool', 'package_config.json');
    logStatus('[flutter] pub get...');
    try {
      await ProcessRunner.runChecked(
        p.join(flutterRoot, 'bin', 'flutter'),
        ['pub', 'get'],
        workingDirectory: projectRoot,
        inheritStdio: true,
        label: 'flutter',
      );
    } on XcrossError {
      if (File(packageConfig).existsSync()) {
        logWarn(
            'Ignoring flutter pub get error because package_config.json exists.');
        return;
      }
      rethrow;
    }
  }

  /// Build `App.framework` via [FlutterDebugBundler].
  /// Returns the framework directory path.
  Future<String> _buildAppFramework(String flutterRoot) async {
    final assembleOut = p.join(projectRoot, 'build', 'xtool-flutter-debug');
    final assembleDir = Directory(assembleOut);
    if (assembleDir.existsSync()) await assembleDir.delete(recursive: true);
    await assembleDir.create(recursive: true);

    return FlutterDebugBundler(
      projectRoot: projectRoot,
      flutterRoot: flutterRoot,
      outputDir: assembleOut,
      entrypoint: options.target,
      dartDefines: options.dartDefines,
      flavor: options.flavor,
    ).build();
  }

  /// Compile the ObjC Runner shim and return both the xcframework path and the
  /// linked Runner binary path.
  Future<({String xcframework, String runnerBinary})> _buildRunnerBinary(
    String flutterRoot,
  ) async {
    final xcframework =
        IosEngineCache(flutterRoot: flutterRoot).flutterXcframework;

    final darwin = DarwinSdk.current();
    if (darwin == null) {
      throw XcrossError(
        'FlutterPacker: Darwin SDK not found. '
        'Install with `xtool sdk install <Xcode.xip|Xcode.app>`.',
      );
    }

    final runnerBinary = await RunnerShim.buildRunnerBinary(
      projectRoot: projectRoot,
      sdk: darwin,
      flutterXcframework: xcframework,
      outputDir: p.join(projectRoot, 'build', 'xtool-flutter-runner-bin'),
    );

    return (xcframework: xcframework, runnerBinary: runnerBinary);
  }

  /// Copy all bundle contents into a temp directory, write `Info.plist`, then
  /// move the result to `build/xtool-ios/<appName>.app`.
  Future<String> _assembleAndPersistBundle({
    required String appFramework,
    required String xcframework,
    required String runnerBinary,
  }) async {
    final flutterFramework =
        p.join(xcframework, 'ios-arm64', 'Flutter.framework');

    // Build the bundle in a temp dir so we can atomically move it to the dest.
    final tmp = await Directory.systemTemp.createTemp('${appName}_app_bundle-');
    final bundleDir = tmp.path;

    final frameworksDir = p.join(bundleDir, 'Frameworks');
    await Directory(frameworksDir).create(recursive: true);

    await File(runnerBinary).copy(p.join(bundleDir, 'Runner'));
    makeExecutable(p.join(bundleDir, 'Runner'));

    await _copyDirectory(
        flutterFramework, p.join(frameworksDir, 'Flutter.framework'));
    await _copyDirectory(appFramework, p.join(frameworksDir, 'App.framework'));

    await _copyOptionalRunnerResources(bundleDir);
    await _writeInfoPlist(bundleDir);

    final dest = p.join(projectRoot, 'build', 'xtool-ios', '$appName.app');
    if (Directory(dest).existsSync()) {
      await Directory(dest).delete(recursive: true);
    }
    await Directory(p.dirname(dest)).create(recursive: true);
    await _copyDirectory(bundleDir, dest);
    await tmp.delete(recursive: true);

    return dest;
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
      if (Directory(dst).existsSync()) {
        await Directory(dst).delete(recursive: true);
      }
      await _copyDirectory(src, dst);
    }
  }

  /// Generate and write `Info.plist` into [bundleDir] with `$(VAR)`
  /// substitution, mandatory iOS keys, storyboard stripping, and ObjC class
  /// name normalization.
  Future<void> _writeInfoPlist(String bundleDir) async {
    final bundleId = schema.idSpecifier.formBundleId(appName);
    var plistXml = await _loadPlistTemplate();

    // ORDER MATTERS: vars must be expanded before forcing keys so that forced
    // keys see already-substituted values from the template, and before
    // storyboard stripping so $(VAR)-valued storyboard names are resolved
    // before the .storyboardc filesystem probe.
    plistXml =
        InfoPlist.expandVars(plistXml, await _buildSubstitutionMap(bundleId));
    plistXml = InfoPlist.applyIosRequiredKeys(plistXml, bundleId: bundleId);
    plistXml = InfoPlist.stripUnsatisfiableStoryboards(plistXml, bundleDir);
    plistXml = InfoPlist.normalizeObjCClassNames(plistXml);

    await File(p.join(bundleDir, 'Info.plist')).writeAsString(plistXml);
  }

  /// Read `ios/Runner/Info.plist` (or `schema.infoPath`), falling back to
  /// [InfoPlist.fallback] when neither exists.
  Future<String> _loadPlistTemplate() async {
    final plistPath = schema.infoPath ?? p.join('ios', 'Runner', 'Info.plist');
    final plistFile = File(p.join(projectRoot, plistPath));
    if (plistFile.existsSync()) return plistFile.readAsString();
    return InfoPlist.fallback;
  }

  /// Build the `$(VAR)` substitution map.
  ///
  /// Precedence (lowest → highest):
  ///   1. Hard-coded defaults (`1.0.0` / `1`).
  ///   2. `Generated.xcconfig` values from `flutter build` tooling.
  ///   3. Explicit `--build-name` / `--build-number` CLI flags.
  Future<Map<String, String>> _buildSubstitutionMap(String bundleId) async {
    final subs = <String, String>{
      'EXECUTABLE_NAME': PlistDefaults.executable,
      'PRODUCT_NAME': PlistDefaults.executable,
      'PRODUCT_MODULE_NAME': PlistDefaults.executable,
      'PRODUCT_BUNDLE_IDENTIFIER': bundleId,
      'DEVELOPMENT_LANGUAGE': 'en',
      'FLUTTER_BUILD_NAME': PlistDefaults.shortVersion,
      'FLUTTER_BUILD_NUMBER': PlistDefaults.bundleVersion,
    };

    final xcconfigFile =
        File(p.join(projectRoot, 'ios', 'Flutter', 'Generated.xcconfig'));
    if (xcconfigFile.existsSync()) {
      subs.addAll(InfoPlist.parseXcconfig(await xcconfigFile.readAsString()));
    }

    if (options.buildName != null) {
      subs['FLUTTER_BUILD_NAME'] = options.buildName!;
    }
    if (options.buildNumber != null) {
      subs['FLUTTER_BUILD_NUMBER'] = options.buildNumber!;
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
