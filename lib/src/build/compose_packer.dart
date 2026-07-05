// Port of scripts/xcross-compose/pipeline.sh → Dart runtime build pipeline.
// Runs INSIDE the xcross-compose (linux/amd64, Apple `container` Rosetta)
// container: konanc is the linux x86_64 prebuilt and runs natively under
// Rosetta, so its two-stage compile + linker subprocess spawns work (unlike an
// arm64 guest + qemu-user, where foreign-exec has no binfmt and aborts).
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import 'package:xcross/src/build/compose_preflight.dart' show resolveLxKn;
import 'package:xcross/src/build/host_manager_patcher.dart';
import 'package:xcross/src/build/ios_app_config.dart';
import 'package:xcross/src/build/kmp_project.dart';
import 'package:xcross/src/constants/apple_toolchain_constants.dart';
import 'package:xcross/src/constants/kotlin_native_constants.dart';
import 'package:xcross/src/constants/plist_defaults.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Builds a Kotlin Multiplatform / Compose Multiplatform iOS `.app` for
/// arm64 (Mach-O) entirely in Dart, replacing the shell pipeline.sh.
///
/// Mirrors `FlutterDebugBundler` in structure; `pack()` returns the `.app`
/// path (= `<kmpProjectRoot>/build/xtool-ios/<appName>.app`) for
/// [KmpEntryKind.runnableApp] projects, or the framework path
/// (`<kmpProjectRoot>/build/xtool-ios/<baseName>.framework`) for
/// [KmpEntryKind.frameworkOnly] projects (e.g. Compose-for-iOS / SwiftUI apps
/// where the Swift host cannot be built on Linux).
///
/// Stages (mirror pipeline.sh 1:1):
///   0. Gradle klib compile + dependency enumeration — REQUIRED, throws on failure.
///   1. Bytecode patch  — patchKotlinNativeJar per jar (idempotent).
///   2. ios_arm64 overlay guard.
///   3. Unified Xcode-shaped toolchain at /tmp/uni.
///   4. Apple shims (PlistBuddy, xcode-select, xcrun).
///   5. konan.properties — POC_PATCH block + runtime targetSysRoot.
///   6. konanc → <baseName>.framework (from gradle-compiled klib).
///   7. <baseName>.xcframework (ios-arm64 slice).
///   8. [runnableApp only] clang compile + ld64.lld link → Runner.
///   9. [runnableApp only] Assemble .app bundle; verify arm64 Mach-O.
class ComposePacker {
  ComposePacker({
    String? kmpProjectRoot,
    String? sdkBundle,
    String? iPhoneSdk,
    String? ld64lld,
    String? appName,
    String? bundleId,
    String? lxKn,
    String? javaHome,
    String? konanDataDir,
    // Module detection fields — provided by detectKmpFramework().
    String? baseName,
    String? moduleName,
    String? modulePath,
    KmpEntryKind? entryKind,
    this.entryClass,
    this.entrySelector,
    // swiftApp fields — provided for KmpEntryKind.swiftApp projects.
    this.swiftSources,
    this.swiftAppDir,
    // Optional: parsed iosApp/Configuration/Config.xcconfig.
    this.iosAppConfig,
    // Optional: path to a user-supplied complete Info.plist (from xtool.yml).
    this.infoPath,
  })  : kmpProjectRoot = kmpProjectRoot ?? Directory.current.path,
        sdkBundle = sdkBundle ?? '',
        iPhoneSdk = iPhoneSdk ?? '',
        ld64lld = (ld64lld != null && ld64lld.isNotEmpty)
            ? ld64lld
            : (Platform.environment['XCROSS_LD64LLD'] ?? '/usr/bin/ld64.lld'),
        appName = appName ?? 'ComposeApp',
        bundleId = bundleId ?? 'com.example.composeApp',
        lxKn = lxKn ??
            (resolveLxKn(Platform.environment) ??
                // Last-ditch fallback: preflight should have caught this, but
                // keep a sensible default so field access stays non-null.
                '${KotlinNativeConstants.defaultKonanRoot}/${KotlinNativeConstants.knDirPrefix}${KotlinNativeConstants.defaultVersion}'),
        javaHome = javaHome ?? (Platform.environment['JAVA_HOME'] ?? ''),
        konanDataDir = (konanDataDir != null && konanDataDir.isNotEmpty)
            ? konanDataDir
            : Platform.environment['KONAN_DATA_DIR'],
        baseName = baseName ?? 'Shared',
        moduleName = moduleName ?? 'shared',
        entryKind = entryKind ?? KmpEntryKind.runnableApp {
    // modulePath defaults to <kmpProjectRoot>/<moduleName> when not provided.
    final root = kmpProjectRoot ?? Directory.current.path;
    final mn = moduleName ?? 'shared';
    this.modulePath = modulePath ?? p.join(root, mn);
  }

  final String kmpProjectRoot;
  final String sdkBundle;
  final String iPhoneSdk;

  /// Full path to the x86_64 ld64.lld used for the framework + Runner link
  /// (env XCROSS_LD64LLD, else the swift image's /usr/bin/ld64.lld). Under the
  /// amd64/Rosetta guest this must be an x86_64 binary — konanc spawns it.
  final String ld64lld;

  final String appName;
  final String bundleId;

  /// K/N linux-x86_64 root (env LX_KN or default).
  final String lxKn;

  /// JDK for konanc + Gradle (native x86_64 under Rosetta; from env JAVA_HOME).
  final String javaHome;

  /// KONAN_DATA_DIR — where konanc keeps its warmed native dependency cache.
  /// Null falls back to konanc's own default (~/.konan). Threaded from the
  /// integrated setup so a freshly provisioned cache is actually used.
  final String? konanDataDir;

  /// Framework baseName, e.g. `Shared`. From [KmpFrameworkModule.baseName].
  final String baseName;

  /// Gradle module name, e.g. `shared`. From [KmpFrameworkModule.moduleName].
  final String moduleName;

  /// Absolute path to the KMP module directory (e.g. `<root>/shared`).
  /// From [KmpFrameworkModule.modulePath].
  late final String modulePath;

  /// Whether this module exposes a Compose/UIKit entry point (runnableApp)
  /// or is a logic-only library (frameworkOnly / SwiftUI host).
  final KmpEntryKind entryKind;

  /// For [KmpEntryKind.runnableApp]: the ObjC companion class generated by
  /// konanc for the Kotlin file, e.g. `MainViewControllerKt`.
  /// The actual ObjC call site uses `<baseName><entryClass>` (i.e.
  /// `SharedMainViewControllerKt`) as the class name.
  final String? entryClass;

  /// For [KmpEntryKind.runnableApp]: the verbatim Kotlin function name,
  /// e.g. `MainViewController` (NOT lowercased — the ObjC selector matches
  /// the Kotlin `fun` name exactly).
  final String? entrySelector;

  /// For [KmpEntryKind.swiftApp]: the sorted list of `.swift` source file
  /// paths to pass to swiftc. From [KmpFrameworkModule.swiftSources].
  final List<String>? swiftSources;

  /// For [KmpEntryKind.swiftApp]: absolute path to the iosApp target source
  /// dir (the dir containing the `@main` file).
  /// From [KmpFrameworkModule.swiftAppDir].
  final String? swiftAppDir;

  /// Parsed `iosApp/Configuration/Config.xcconfig`, or null when absent.
  /// Provides `productName`, `bundleId`, and version strings for Stage 9
  /// Info.plist synthesis on [KmpEntryKind.swiftApp] projects.
  final IosAppConfig? iosAppConfig;

  /// Optional path to a user-supplied, complete Info.plist (from `xtool.yml`
  /// `infoPath` key). When set and the file contains `CFBundleExecutable`,
  /// Stage 9 uses it verbatim instead of synthesising one.
  final String? infoPath;

  // ---------------------------------------------------------------------------
  // Class-level constants
  // ---------------------------------------------------------------------------

  /// Unified Xcode-shaped toolchain directory built in Stage 3.
  static const _uniToolchainDir = '/tmp/uni';

  /// Mocked Xcode version returned by the PlistBuddy shim (Stage 4).
  static const _mockXcodeVersion = '16.0';

  /// Fallback iOS SDK platform version passed to ld64.lld in Stage 8.
  static const _fallbackPlatformVersion = '26.5';

  /// Environment overrides injected into every konanc/gradle spawn: the native
  /// JDK and the warmed konan cache (both may live outside the parent env).
  /// Also prepends `$JAVA_HOME/bin` to PATH so children that expect `java` on
  /// PATH (not just JAVA_HOME) resolve the provisioned JDK.
  Map<String, String> get _toolEnv {
    final env = <String, String>{
      if (javaHome.isNotEmpty) 'JAVA_HOME': javaHome,
      if (konanDataDir != null && konanDataDir!.isNotEmpty)
        'KONAN_DATA_DIR': konanDataDir!,
    };
    if (javaHome.isNotEmpty) {
      final parentPath = Platform.environment['PATH'] ?? '';
      final javaBin = p.join(javaHome, 'bin');
      env['PATH'] = parentPath.isEmpty ? javaBin : '$javaBin:$parentPath';
    }
    return env;
  }

  /// Leaf segment of [moduleName] — last component after the last `:`.
  ///
  /// For flat modules (`shared`) equals [moduleName].
  /// For nested modules (`a:b`) returns `b`.
  /// Used in Gradle init-script `name` guards and klib directory names.
  String get _moduleLeaf => moduleName.split(':').last;

  // Stage 0 populates these for Stage 6.
  late List<String> _depKlibs;

  // ---------------------------------------------------------------------------
  // Public entry point
  // ---------------------------------------------------------------------------

  /// Run all stages and return the output path.
  ///
  /// For [KmpEntryKind.runnableApp]: returns the `.app` bundle path.
  /// For [KmpEntryKind.frameworkOnly]: returns the `<baseName>.framework`
  /// path and logs a warning (SwiftUI runner cannot be built on Linux).
  Future<String> pack() async {
    logStatus('');
    logStatus('== [xcross-compose] Host ==');
    logStatus('  KMP:    $kmpProjectRoot');
    logStatus('  SDK:    $sdkBundle');
    logStatus('  iPhone: $iPhoneSdk');
    logStatus('  K/N:    $lxKn');
    logStatus('  app:    $appName ($bundleId)');
    logStatus('  module: $moduleName  baseName: $baseName  kind: $entryKind');

    await _stage0GradleKlib();
    await _stage1BytecodePatch();
    await _stage2IosArm64Overlay();
    await _stage3UnifiedToolchain();
    await _stage4AppleShims();
    await _stage5KonanProperties();
    final frameworkDir = await _stage6Konanc();

    // ── swiftApp path: SKIP stage 7 (xcframework) — swiftc links the
    // framework directory produced by stage 6 directly.
    if (entryKind == KmpEntryKind.swiftApp) {
      final runnerBin = await _stage8SwiftRunner(frameworkDir);
      return _stage9Assemble(runnerBin, frameworkDir);
    }

    await _stage7Xcframework(frameworkDir);

    if (entryKind == KmpEntryKind.frameworkOnly) {
      // Place the built framework at build/xtool-ios/<baseName>.framework.
      final outDir = p.join(kmpProjectRoot, 'build', 'xtool-ios');
      await Directory(outDir).create(recursive: true);
      final outFramework = p.join(outDir, '$baseName.framework');
      final outFwDir = Directory(outFramework);
      if (outFwDir.existsSync()) await outFwDir.delete(recursive: true);
      await _copyDirectory(frameworkDir, outFramework);
      logWarn(
        'Compose/SwiftUI iOS app not buildable on Linux (SwiftUI Runner). '
        'Produced framework only: $outFramework.',
      );
      return outFramework;
    }

    // runnableApp: ObjC clang + ld64.lld runner.
    final runnerBin = await _stage8ClangLink(frameworkDir);
    return _stage9Assemble(runnerBin, frameworkDir);
  }

  // ---------------------------------------------------------------------------
  // Stage 0: Gradle klib compile + dependency enumeration (REQUIRED)
  // ---------------------------------------------------------------------------

  Future<void> _stage0GradleKlib() async {
    logStatus('');
    logStatus('== [xcross-compose] Stage 0: gradle klib compile + dep enum ==');

    // Prefer the project's Gradle wrapper — it bootstraps the exact Gradle
    // version the project pins. Fall back to system `gradle` only if absent.
    final wrapper = p.join(kmpProjectRoot, 'gradlew');
    final hasWrapper = File(wrapper).existsSync();
    final gradleExe = hasWrapper ? wrapper : 'gradle';
    if (!hasWrapper) {
      logStatus('  [gradle] no ./gradlew wrapper found; trying system gradle');
    }

    // ── Step 2 prep: allocate temp paths BEFORE building gradleEnv so the
    // output path can be passed via env var (N3: avoids path interpolation in
    // Kotlin source where special characters could break the init-script).
    final tmpDir = Directory.systemTemp.createTempSync('xcross_deps_');
    final depsOutPath = p.join(tmpDir.path, 'iosDeps.txt');
    final initScriptPath = p.join(tmpDir.path, 'dumpDeps.init.gradle.kts');

    final gradleEnv = {
      ...Platform.environment,
      ..._toolEnv,
      // N3: pass output path via env var so the Kotlin init-script never has
      // to interpolate a file-system path that might contain special chars.
      'XCROSS_DEPS_OUT': depsOutPath,
    };

    // ── Step 1: compile the klib (resolves all Compose deps) ─────────────────
    logStatus('  [gradle] :$moduleName:compileKotlinIosArm64 ...');
    await ProcessRunner.runChecked(
      gradleExe,
      [
        ':$moduleName:compileKotlinIosArm64',
        '-Pkotlin.native.enableKlibsCrossCompilation=true',
        '--no-daemon',
        '--console=plain',
      ],
      workingDirectory: kmpProjectRoot,
      environment: gradleEnv,
      includeParentEnvironment: false,
      inheritStdio: true,
      label: hasWrapper ? 'gradlew' : 'gradle',
    );
    logStatus('  [gradle] klib compile complete');

    // ── Step 2: enumerate compile-time dependency klibs via init-script ──────
    // The init-script uses reflection because KGP types are NOT on the
    // init-script classpath; typed references fail to compile. This exact form
    // is proven to work.  --no-configuration-cache is required because the task
    // reads `project` at execution time (config cache forbids that).
    //
    // N3: the output path is read via System.getenv("XCROSS_DEPS_OUT") instead
    // of being interpolated as a string literal — avoids any special-char risk.
    // S2: use _moduleLeaf for the `name` guard so nested modules (:a:b → leaf
    // is `b`) match the Gradle project name correctly.
    final leaf = _moduleLeaf;
    final initScriptContent = '''
allprojects {
    if (name != "$leaf") return@allprojects
    tasks.register("dumpIosDeps") {
        dependsOn("compileKotlinIosArm64")
        doLast {
            val outPath = System.getenv("XCROSS_DEPS_OUT") ?: error("XCROSS_DEPS_OUT not set")
            val kotlinExt = project.extensions.findByName("kotlin") ?: error("no kotlin extension")
            val targets = kotlinExt.javaClass.getMethod("getTargets").invoke(kotlinExt)
            val findByName = targets.javaClass.methods.first { it.name == "findByName" }
            val target = findByName.invoke(targets, "iosArm64") ?: error("no iosArm64 target")
            val compilations = target.javaClass.getMethod("getCompilations").invoke(target)
            val getByName = compilations.javaClass.methods.first { it.name == "getByName" && it.parameterCount == 1 }
            val main = getByName.invoke(compilations, "main")
            val cdf = main.javaClass.methods.first { it.name == "getCompileDependencyFiles" }.invoke(main)
            @Suppress("UNCHECKED_CAST")
            val files = cdf.javaClass.getMethod("getFiles").invoke(cdf) as Set<java.io.File>
            java.io.File(outPath).writeText(files.joinToString("\\n") { it.absolutePath })
        }
    }
}
''';
    await File(initScriptPath).writeAsString(initScriptContent);

    logStatus('  [gradle] :$moduleName:dumpIosDeps (dep enumeration) ...');
    await ProcessRunner.runChecked(
      gradleExe,
      [
        ':$moduleName:dumpIosDeps',
        '--init-script',
        initScriptPath,
        '--no-daemon',
        '--no-configuration-cache',
        '--console=plain',
      ],
      workingDirectory: kmpProjectRoot,
      environment: gradleEnv,
      includeParentEnvironment: false,
      inheritStdio: true,
      label: hasWrapper ? 'gradlew(deps)' : 'gradle(deps)',
    );

    // Read output and filter to existing .klib paths.
    final depsOutFile = File(depsOutPath);
    if (!depsOutFile.existsSync()) {
      throw XcrossError(
        '[xcross-compose] Stage 0: dep enumeration output not found at '
        '$depsOutPath. The dumpIosDeps task may not have run.',
      );
    }
    final rawLines = depsOutFile.readAsStringSync().split('\n');
    // S3: accept file OR directory — project-to-project deps and commonized
    // deps can be unpacked klib directories (File.existsSync() returns false
    // for dirs → silently dropped under the old check).
    // S4: exclude klibs already under lxKn — konanc auto-links platform libs
    // for -target ios_arm64; passing them as -library risks duplicate-module
    // errors.
    final lxKnNorm = lxKn.endsWith(p.separator) ? lxKn : '$lxKn${p.separator}';
    _depKlibs = rawLines
        .map((l) => l.trim())
        .where((l) =>
            l.endsWith('.klib') &&
            FileSystemEntity.typeSync(l) != FileSystemEntityType.notFound &&
            !l.startsWith(lxKnNorm))
        .toList();

    // Clean up temp files.
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}

    logStatus('  [gradle] ${_depKlibs.length} dependency klibs resolved');
  }

  // ---------------------------------------------------------------------------
  // Stage 1: Bytecode patch — find kotlin-native-compiler-embeddable.jar(s)
  // ---------------------------------------------------------------------------

  Future<void> _stage1BytecodePatch() async {
    logStatus('');
    logStatus(
        '== [xcross-compose] Stage 1: bytecode patch (HostManager + ObjCExportKt) ==');

    final jars = <String>[];
    await for (final entity in Directory(lxKn).list(recursive: true)) {
      if (entity is File &&
          p.basename(entity.path) == 'kotlin-native-compiler-embeddable.jar') {
        jars.add(entity.path);
      }
    }

    for (final jar in jars) {
      patchKotlinNativeJar(jar);
    }
    logStatus('  [konanc] jar patch complete (idempotent)');
  }

  // ---------------------------------------------------------------------------
  // Stage 2: ios_arm64 overlay guard
  // ---------------------------------------------------------------------------

  Future<void> _stage2IosArm64Overlay() async {
    logStatus('');
    logStatus('== [xcross-compose] Stage 2: ios_arm64 overlay (guard) ==');

    final targetsDir = p.join(lxKn, 'konan', 'targets', 'ios_arm64');
    final klibDir = p.join(lxKn, 'klib', 'platform', 'ios_arm64');

    final targetsDirExists = Directory(targetsDir).existsSync();
    final klibDirExists = Directory(klibDir).existsSync();
    if (targetsDirExists && klibDirExists) {
      logStatus('  ios_arm64 overlay present — skipping');
      return;
    }

    final overlay = Platform.environment['KN_IOS_OVERLAY'] ?? '';
    final overlayTargetExists = Directory(
      p.join(overlay, 'konan', 'targets', 'ios_arm64'),
    ).existsSync();
    if (overlay.isNotEmpty && overlayTargetExists) {
      logStatus('  overlaying from KN_IOS_OVERLAY mount ...');
      await Directory(p.join(lxKn, 'konan', 'targets')).create(recursive: true);
      await Directory(p.join(lxKn, 'klib', 'platform')).create(recursive: true);
      await _copyDirectory(
        p.join(overlay, 'konan', 'targets', 'ios_arm64'),
        p.join(lxKn, 'konan', 'targets', 'ios_arm64'),
      );
      await _copyDirectory(
        p.join(overlay, 'klib', 'platform', 'ios_arm64'),
        p.join(lxKn, 'klib', 'platform', 'ios_arm64'),
      );
      logStatus('  overlay complete');
      return;
    }

    throw XcrossError(
      '[xcross-compose] ERROR: ios_arm64 overlay missing and KN_IOS_OVERLAY not set.\n'
      '  Rebuild the xcross-compose image to bake the overlay in.',
    );
  }

  // ---------------------------------------------------------------------------
  // Stage 3: unified Xcode-shaped toolchain at /tmp/uni
  // ---------------------------------------------------------------------------

  Future<void> _stage3UnifiedToolchain() async {
    logStatus('');
    logStatus('== [xcross-compose] Stage 3: unified toolchain at /tmp/uni ==');

    final uniUsrBin = Directory('$_uniToolchainDir/usr/bin');
    final uniUsrLib = Directory('$_uniToolchainDir/usr/lib');
    await uniUsrBin.create(recursive: true);
    await uniUsrLib.create(recursive: true);

    final toolsetBin = p.join(sdkBundle, 'toolset', 'bin');

    // Symlink all toolset/bin/* → /tmp/uni/usr/bin/.
    final toolsetBinExists = Directory(toolsetBin).existsSync();
    if (toolsetBinExists) {
      await for (final entity in Directory(toolsetBin).list()) {
        final name = p.basename(entity.path);
        final link = Link(p.join(uniUsrBin.path, name));
        final linkExists = link.existsSync();
        if (!linkExists) {
          try {
            await link.create(entity.path);
          } catch (_) {}
        }
      }
    }

    // Symlink XcodeDefault clang headers.
    final xcd = p.join(
        sdkBundle, 'Developer', 'Toolchains', 'XcodeDefault.xctoolchain');
    final clangSrc = p.join(xcd, 'usr', 'lib', 'clang');
    final clangDst = p.join(uniUsrLib.path, 'clang');
    final clangSrcExists = Directory(clangSrc).existsSync();
    final clangDstLinkExists = Link(clangDst).existsSync();
    if (clangSrcExists && !clangDstLinkExists) {
      await Link(clangDst).create(clangSrc);
    }

    // ld wrapper — exec the x86_64 iOS-capable ld64.lld (konanc's
    // linker.ios_arm64). The swift image's own lld is stubbed for Apple
    // platforms; XCROSS_LD64LLD points at stock LLVM's ld64.lld instead.
    final ldWrapper = File(p.join(uniUsrBin.path, 'ld'));
    await ldWrapper.writeAsString('#!/bin/bash\nexec $ld64lld "\$@"\n');
    _chmod(ldWrapper.path, '+x');

    // Tool stubs: satisfy xcrun -f probes.
    const stubs = [
      'bitcode-build-tool',
      'clang',
      'clang++',
      'swift',
      'swiftc',
      'strip',
      'ar',
      'nm',
      'libtool',
      'dsymutil',
    ];
    for (final tool in stubs) {
      final stub = File(p.join(uniUsrBin.path, tool));
      if (!stub.existsSync()) {
        await stub.writeAsString('#!/bin/bash\nexit 0\n');
        _chmod(stub.path, '+x');
      }
    }

    logStatus('  /tmp/uni/usr/bin/ld → $ld64lld');
  }

  // ---------------------------------------------------------------------------
  // Stage 4: Apple shims (PlistBuddy, xcode-select, xcrun)
  // ---------------------------------------------------------------------------

  Future<void> _stage4AppleShims() async {
    logStatus('');
    logStatus('== [xcross-compose] Stage 4: Apple shims ==');

    await Directory('/usr/libexec').create(recursive: true);

    // PlistBuddy.
    final plistBuddy = File(AppleToolchainConstants.plistBuddy);
    await plistBuddy.writeAsString('#!/bin/bash\necho "$_mockXcodeVersion"\nexit 0\n');
    _chmod(plistBuddy.path, '+x');

    // xcode-select -p.
    final xcodeSelect = File(AppleToolchainConstants.xcodeSelect);
    await xcodeSelect.writeAsString(
        '#!/bin/bash\nprintf "%s/Developer\\n" "$sdkBundle"\nexit 0\n'
            .replaceAll(r'$sdkBundle', sdkBundle));
    _chmod(xcodeSelect.path, '+x');

    // xcrun dispatch table (built via StringBuffer — avoids leading_newlines lint).
    final xcrunBuf = StringBuffer()
      ..writeln('#!/bin/bash')
      ..writeln(r'echo "[xcrun] $*" >> /tmp/xcrun.log')
      ..writeln(r'case "$*" in')
      ..writeln(
          '  "xcodebuild -version"|"-version") echo ${AppleToolchainConstants.xcodeVersion}; echo "Build version ${AppleToolchainConstants.xcodeBuild}" ;;')
      ..writeln('  "-f ld") echo $_uniToolchainDir/usr/bin/ld ;;')
      ..writeln(
          '  "-f bitcode-build-tool") echo $_uniToolchainDir/usr/bin/bitcode-build-tool ;;')
      ..writeln('  "-f clang") echo /usr/bin/clang ;;')
      ..writeln('  "--find clang") echo /usr/bin/clang ;;')
      ..writeln('  "-f clang++") echo /usr/bin/clang++ ;;')
      ..writeln('  "-f swift") echo /usr/bin/swift ;;')
      ..writeln('  "--find swift") echo /usr/bin/swift ;;')
      ..writeln('  "-f swiftc") echo /usr/bin/swiftc ;;')
      ..writeln('  "-f ar") echo /usr/bin/ar ;;')
      ..writeln('  "--find ar") echo /usr/bin/ar ;;')
      ..writeln('  "-f nm") echo /usr/bin/nm ;;')
      ..writeln('  "-f strip") echo /usr/bin/strip ;;')
      ..writeln('  "-f ranlib") echo /usr/bin/ar ;;')
      ..writeln('  "-f libtool") echo $_uniToolchainDir/usr/bin/libtool ;;')
      ..writeln('  "-f dsymutil") echo $_uniToolchainDir/usr/bin/dsymutil ;;')
      ..writeln('  "--find dsymutil") echo $_uniToolchainDir/usr/bin/dsymutil ;;')
      ..writeln('  "--sdk iphoneos --show-sdk-path") echo $iPhoneSdk ;;')
      ..writeln('  "--sdk macosx --show-sdk-path") echo $iPhoneSdk ;;')
      ..writeln('  "--sdk iphonesimulator --show-sdk-path") echo $iPhoneSdk ;;')
      ..writeln('  "simctl list runtimes -j") echo "{}" ;;')
      ..writeln('  *) echo /usr/bin/false ;;')
      ..writeln('esac')
      ..writeln('exit 0');
    final xcrunContent = xcrunBuf.toString();
    final xcrun = File(AppleToolchainConstants.xcrun);
    await xcrun.writeAsString(xcrunContent);
    _chmod(xcrun.path, '+x');

    logStatus('  PlistBuddy, xcode-select, xcrun shims installed');
  }

  // ---------------------------------------------------------------------------
  // Stage 5: konan.properties — POC_PATCH block + runtime targetSysRoot
  // ---------------------------------------------------------------------------

  Future<void> _stage5KonanProperties() async {
    logStatus('');
    logStatus(
        '== [xcross-compose] Stage 5: konan.properties — POC_PATCH block + runtime targetSysRoot ==');

    final konanProps = File(p.join(lxKn, 'konan', 'konan.properties'));

    // Idempotently append POC_PATCH stub block (guard on marker comment).
    const pocMarker = '# POC_PATCH';
    final konanPropsExists = konanProps.existsSync();
    final existing =
        konanPropsExists ? await konanProps.readAsString() : '';

    if (!existing.contains(pocMarker)) {
      const appleTargets = [
        'ios_arm32',
        'ios_arm64',
        'ios_simulator_arm64',
        'ios_x64',
        'macos_arm64',
        'macos_x64',
        'tvos_arm64',
        'tvos_simulator_arm64',
        'tvos_x64',
        'watchos_arm32',
        'watchos_arm64',
        'watchos_device_arm64',
        'watchos_simulator_arm64',
        'watchos_x64',
      ];

      final buf = StringBuffer();
      buf.writeln();
      buf.writeln(
          '# POC_PATCH — xcross-compose: Linux arm64 → ios_arm64 cross-build stubs.');
      for (final t in appleTargets) {
        buf.writeln('targetSysRoot.$t = /tmp/uni/usr');
        buf.writeln('targetToolchain.linux_x64-$t = /tmp/uni/usr');
        buf.writeln('additionalToolsDir.$t = /tmp/uni/usr');
      }
      buf.writeln('additionalToolsDir.linux_x64 = /tmp/uni/usr');
      // stub ios_arm64 sysroot; overridden below (last-wins).
      buf.writeln('targetSysRoot.ios_arm64 = /tmp/uni/usr');
      // linker: the ld wrapper built in Stage 3.
      buf.writeln('linker.ios_arm64 = /tmp/uni/usr/bin/ld');

      await konanProps.writeAsString(existing + buf.toString());
      logStatus('  konan.properties: POC_PATCH block appended');
    } else {
      logStatus('  konan.properties: POC_PATCH already present');
    }

    // Always append runtime real targetSysRoot.ios_arm64 (last-wins append).
    // konan.properties uses last-wins semantics: the final occurrence of a key
    // wins, so appending here overrides the /tmp/uni/usr stub in POC_PATCH.
    final runtimePatch = '\n'
        '# RUNTIME_PATCH — real iPhoneOS.sdk (appended by ComposePacker; overrides stub)\n'
        'targetSysRoot.ios_arm64 = $iPhoneSdk\n';
    // Intentional re-read: pick up the POC_PATCH block (just written above, or
    // already present from a prior run) before appending so it is not lost.
    await konanProps.writeAsString(
      (await konanProps.readAsString()) + runtimePatch,
    );
    logStatus('  targetSysRoot.ios_arm64 = $iPhoneSdk');
  }

  // ---------------------------------------------------------------------------
  // Stage 6: konanc → <baseName>.framework from gradle-compiled klib
  // ---------------------------------------------------------------------------

  Future<String> _stage6Konanc() async {
    logStatus('');
    logStatus(
        '== [xcross-compose] Stage 6: [konanc] ios_arm64 framework from klib ==');

    // The module klib is an unpacked directory produced by compileKotlinIosArm64.
    // S2: use _moduleLeaf (leaf of nested module name, e.g. 'b' for ':a:b')
    // as the klib directory name — Gradle uses the leaf, not the full path.
    final moduleKlibDir = p.join(
      modulePath,
      'build',
      'classes',
      'kotlin',
      'iosArm64',
      'main',
      'klib',
      _moduleLeaf,
    );
    if (!Directory(moduleKlibDir).existsSync()) {
      throw XcrossError(
        '[xcross-compose] Stage 6: module klib not found at $moduleKlibDir.\n'
        'Ensure Stage 0 (gradle klib compile) completed successfully.',
      );
    }
    logStatus('  [konanc] klib: $moduleKlibDir');
    logStatus('  [konanc] deps: ${_depKlibs.length} klibs');

    final outDir = p.join(
        modulePath, 'build', 'bin', 'iosArm64', 'debugFramework');
    await Directory(outDir).create(recursive: true);

    // Build -library list from dep klibs (resolved by Stage 0).
    final libraryArgs = <String>[];
    for (final klib in _depKlibs) {
      libraryArgs.addAll(['-library', klib]);
    }

    // konanc runs natively (x86_64 under Rosetta) with the native JDK.
    // NB: NO `-opt`. Debug framework — `-opt` enables release LLVM LTO which
    // OOM-kills the compiler (exit 137) under a memory-limited guest.
    // NB: Do NOT add -Xoverride-konan-properties here; Stage 5 already patched
    // konan.properties in-place (the patcher's designed approach).
    final konanc = p.join(lxKn, 'bin', 'konanc');
    await ProcessRunner.runChecked(
      konanc,
      [
        '-target',
        'ios_arm64',
        '-p',
        'framework',
        '-Xadd-light-debug=disable',
        '-Xbinary=bundleId=$bundleId',
        '-Xinclude=$moduleKlibDir',
        ...libraryArgs,
        '-o',
        p.join(outDir, baseName),
      ],
      workingDirectory: kmpProjectRoot,
      environment: {
        ...Platform.environment,
        ..._toolEnv,
      },
      includeParentEnvironment: false,
      inheritStdio: true,
      label: 'konanc',
    );

    final frameworkDir = p.join(outDir, '$baseName.framework');
    final binaryExists =
        File(p.join(frameworkDir, baseName)).existsSync();
    final headerExists =
        File(p.join(frameworkDir, 'Headers', '$baseName.h')).existsSync();
    if (!binaryExists) {
      throw XcrossError(
        '[xcross-compose] FAIL: $baseName.framework/$baseName binary not produced.\n'
        'Check $kmpProjectRoot/kmp-link.log for details.',
      );
    }
    if (!headerExists) {
      logWarn(
          '  [konanc] WARNING: $baseName.framework/Headers/$baseName.h not found.');
    }
    logStatus('  [konanc] $baseName.framework produced');
    return frameworkDir;
  }

  // ---------------------------------------------------------------------------
  // Stage 7: wrap <baseName>.framework → <baseName>.xcframework (ios-arm64)
  // ---------------------------------------------------------------------------

  Future<void> _stage7Xcframework(String frameworkDir) async {
    logStatus('');
    logStatus('== [xcross-compose] Stage 7: $baseName.xcframework ==');

    final xcf = p.join(kmpProjectRoot, 'iosApp', '$baseName.xcframework');
    final xcfDir = Directory(xcf);
    final xcfDirExists = xcfDir.existsSync();
    if (xcfDirExists) await xcfDir.delete(recursive: true);
    await Directory(p.join(xcf, 'ios-arm64')).create(recursive: true);

    // Copy <baseName>.framework into ios-arm64 slice.
    await _copyDirectory(
        frameworkDir, p.join(xcf, 'ios-arm64', '$baseName.framework'));

    // Write Info.plist.
    final plist = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
        ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        '<dict>\n'
        '  <key>AvailableLibraries</key>\n'
        '  <array>\n'
        '    <dict>\n'
        '      <key>BinaryPath</key><string>$baseName.framework/$baseName</string>\n'
        '      <key>LibraryIdentifier</key><string>ios-arm64</string>\n'
        '      <key>LibraryPath</key><string>$baseName.framework</string>\n'
        '      <key>SupportedArchitectures</key><array><string>arm64</string></array>\n'
        '      <key>SupportedPlatform</key><string>ios</string>\n'
        '    </dict>\n'
        '  </array>\n'
        '  <key>CFBundlePackageType</key><string>XFWK</string>\n'
        '  <key>XCFrameworkFormatVersion</key><string>1.0</string>\n'
        '</dict>\n'
        '</plist>\n';
    await File(p.join(xcf, 'Info.plist')).writeAsString(plist);

    logStatus('  $baseName.xcframework → $xcf');
  }

  // ---------------------------------------------------------------------------
  // Stage 8 (swift): [swiftApp] swiftc SwiftUI Runner
  // ---------------------------------------------------------------------------

  /// Compile the project's real `iosApp/**/*.swift` sources into a Runner
  /// binary by invoking `swiftc` directly against the [KmpEntryKind.swiftApp]
  /// stage-6 framework directory.
  ///
  /// Stage 7 (xcframework wrap) is SKIPPED for swiftApp — swiftc resolves the
  /// framework by `-F <frameworkParentDir>`.
  ///
  /// The exact flag list is isolated in [_swiftcArgs] so container-validation
  /// spikes (U1 ld selection, U2 SwiftUI module resolution, U3 resource-dir,
  /// U5 runtime references) can adjust a single method without touching the
  /// rest of the stage.
  Future<String> _stage8SwiftRunner(String frameworkDir) async {
    logStatus('');
    logStatus('== [xcross-compose] Stage 8 (swift): swiftc SwiftUI Runner ==');
    logStatus('  baseName:  $baseName');
    logStatus('  sources:   ${(swiftSources ?? []).length} Swift files');
    if (swiftAppDir != null) logStatus('  swiftAppDir: $swiftAppDir');

    if (swiftSources == null || swiftSources!.isEmpty) {
      throw XcrossError(
        '[xcross-compose] Stage 8 (swift): no Swift sources to compile. '
        'Ensure the iosApp directory contains .swift files and was detected '
        'as entryKind=swiftApp.',
      );
    }

    final buildDir = p.join(kmpProjectRoot, 'build', 'xtool-compose');
    await Directory(buildDir).create(recursive: true);
    final runnerBin = p.join(buildDir, 'Runner');

    // dir CONTAINING <baseName>.framework (stage 6 output parent)
    final frameworkParentDir = p.dirname(frameworkDir);

    // Swift resource dir inside the Darwin SDK toolchain.
    final resourceDir = p.join(
      sdkBundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
    );
    final clangBuiltinIncludeDir = _clangBuiltinIncludeDir(resourceDir);
    if (clangBuiltinIncludeDir == null) {
      logWarn(
        '  [swiftc] WARNING: Clang builtin headers not found; '
        'Swift C importer may fail on stdarg.h/stdint.h.',
      );
    } else {
      logStatus('  [swiftc] clang builtins: $clangBuiltinIncludeDir');
    }

    final moduleCacheDir = p.join(buildDir, 'swift-module-cache');
    await Directory(moduleCacheDir).create(recursive: true);

    final args = _swiftcArgs(
      frameworkParentDir: frameworkParentDir,
      resourceDir: resourceDir,
      clangBuiltinIncludeDir: clangBuiltinIncludeDir,
      moduleCacheDir: moduleCacheDir,
      runnerBin: runnerBin,
    );

    logStatus('  [swiftc] linking Runner with -use-ld=$ld64lld ...');
    await ProcessRunner.runChecked(
      'swiftc',
      args,
      workingDirectory: kmpProjectRoot,
      inheritStdio: true,
      label: 'swiftc',
    );

    if (!File(runnerBin).existsSync()) {
      throw XcrossError(
        '[xcross-compose] Stage 8 (swift): Runner binary not produced.\n'
        'Review swiftc output above.',
      );
    }

    // Best-effort Mach-O verification (same pattern as ObjC stage 8).
    final fileResult = await ProcessRunner.run('file', [runnerBin]);
    final fileOut = fileResult.stdout.trim();
    logStatus('  [swiftc] Runner: $fileOut');
    if (!fileOut.contains('arm64') &&
        !fileOut.contains('aarch64') &&
        !fileOut.contains('Mach-O')) {
      logWarn('Runner may not be arm64 Mach-O — check swiftc output.');
    }

    logStatus('  [swiftc] Stage 8 complete → $runnerBin');
    return runnerBin;
  }

  /// Build the swiftc argument list for the SwiftUI Runner.
  ///
  /// ALL flags live here — a single place to adjust for container spikes:
  ///   U1: -use-ld selection (must be the x86_64 iOS-capable ld64.lld, NOT
  ///       the aarch64 bundle linker; packer.ld64lld is already correct).
  ///   U2: SwiftUI module resolution (-F frameworkParentDir + -resource-dir).
  ///   U3: -resource-dir path (relative to sdkBundle toolchain root).
  ///   U5: Swift runtime references (-Xlinker -rpath).
  List<String> _swiftcArgs({
    required String frameworkParentDir,
    required String resourceDir,
    required String? clangBuiltinIncludeDir,
    required String moduleCacheDir,
    required String runnerBin,
  }) {
    // Minimum iOS version for SwiftUI App lifecycle (@main struct : App).
    const iosMin = '15.0';

    return [
      if (Platform.environment['XCROSS_SWIFTC_VERBOSE'] == '1') '-v',
      // ── Target ────────────────────────────────────────────────────────────
      '-sdk', iPhoneSdk,
      '-target', 'arm64-apple-ios$iosMin',
      // U3: Swift stdlib + overlays live here inside the Darwin SDK toolchain.
      '-resource-dir', resourceDir,
      // ── Framework search ──────────────────────────────────────────────────
      // U2: dir containing <baseName>.framework (stage 6 debugFramework output).
      '-F', frameworkParentDir,
      '-framework', baseName,
      // ── Compilation mode ──────────────────────────────────────────────────
      '-parse-as-library',          // required for @main App lifecycle
      '-module-cache-path', moduleCacheDir,
      // ── Linker selection ──────────────────────────────────────────────────
      // U1: use the packer's x86_64 iOS-capable ld64.lld (NOT the bundle's
      // aarch64 ld). The `-use-ld=` flag accepts a full path.
      '-use-ld=$ld64lld',
      // ── Cross-import overlays ─────────────────────────────────────────────
      '-Xfrontend', '-enable-cross-import-overlays',
      '-Xfrontend', '-disable-modules-validate-system-headers',
      // Keep Clang importer on the iPhone SDK headers. Without this, Linux
      // stdlib headers can leak into Darwin modules and trigger
      // `_c_standard_library_obsolete` / incompatible-header diagnostics.
      '-Xcc', '-isysroot', '-Xcc', iPhoneSdk,
      if (clangBuiltinIncludeDir != null) ...[
        '-Xcc', '-isystem', '-Xcc', clangBuiltinIncludeDir,
      ],
      // ── Runtime rpath ─────────────────────────────────────────────────────
      // U5: stage 9 places <baseName>.framework under Frameworks/; rpath lets
      // the dyld loader find it at runtime without signing gymnastics.
      '-Xlinker', '-rpath', '-Xlinker', '@executable_path/Frameworks',
      // ── Sources ──────────────────────────────────────────────────────────
      ...swiftSources!,
      // ── Output ───────────────────────────────────────────────────────────
      '-o', runnerBin,
    ];
  }

  String? _clangBuiltinIncludeDir(String resourceDir) {
    final candidates = <String>[
      p.join(resourceDir, 'clang', 'include'),
      '/usr/lib/swift/clang/include',
    ];

    final llvmLib = Directory('/usr/lib/llvm-18/lib/clang');
    if (llvmLib.existsSync()) {
      final versionDirs = llvmLib
          .listSync(followLinks: false)
          .whereType<Directory>()
          .map((dir) => p.join(dir.path, 'include'))
          .toList()
        ..sort();
      candidates.addAll(versionDirs.reversed);
    }

    for (final dir in candidates) {
      if (File(p.join(dir, 'stdarg.h')).existsSync()) return dir;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Stage 8: [runnableApp] generate main.m + clang compile + ld64.lld link
  // ---------------------------------------------------------------------------

  Future<String> _stage8ClangLink(String frameworkDir) async {
    logStatus('');
    logStatus('== [xcross-compose] Stage 8: [clang] + [ld64.lld] Runner ==');

    final runnerBuild = p.join(kmpProjectRoot, 'iosApp', '.build', 'runner');
    final runnerBuildDir = Directory(runnerBuild);
    final runnerBuildDirExists = runnerBuildDir.existsSync();
    if (runnerBuildDirExists) {
      await runnerBuildDir.delete(recursive: true);
    }
    await runnerBuildDir.create(recursive: true);

    final xcfRoot =
        p.join(kmpProjectRoot, 'iosApp', '$baseName.xcframework', 'ios-arm64');
    final fwHeaders = p.join(xcfRoot, '$baseName.framework', 'Headers');

    // Generate main.m under build/xtool-compose/Runner/ — NOT into the source
    // tree (examples ship no main.m; this is generated for each build).
    final generatedRunnerDir =
        p.join(kmpProjectRoot, 'build', 'xtool-compose', 'Runner');
    await Directory(generatedRunnerDir).create(recursive: true);
    final mainM = p.join(generatedRunnerDir, 'main.m');

    // ObjC entry point:
    //   class  = <baseName><entryClass>  e.g. SharedMainViewControllerKt
    //   selector = <entrySelector>       e.g. MainViewController (verbatim)
    final objcClass = '$baseName${entryClass ?? 'MainViewControllerKt'}';
    final objcSelector = entrySelector ?? 'MainViewController';

    final mainMContent = '#import <UIKit/UIKit.h>\n'
        '#import <$baseName/$baseName.h>\n'
        '@interface AppDelegate : UIResponder <UIApplicationDelegate>\n'
        '@property (strong, nonatomic) UIWindow *window;\n'
        '@end\n'
        '@implementation AppDelegate\n'
        '- (BOOL)application:(UIApplication *)application '
        'didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {\n'
        '    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];\n'
        '    self.window.rootViewController = [$objcClass $objcSelector];\n'
        '    [self.window makeKeyAndVisible];\n'
        '    return YES;\n'
        '}\n'
        '@end\n'
        'int main(int argc, char *argv[]) {\n'
        '    @autoreleasepool { return UIApplicationMain(argc, argv, nil, '
        'NSStringFromClass([AppDelegate class])); }\n'
        '}\n';
    await File(mainM).writeAsString(mainMContent);
    logStatus('  [stage8] generated main.m → $mainM');

    final runnerObj = await _compileRunnerObj(
      runnerBuild: runnerBuild,
      xcfRoot: xcfRoot,
      mainM: mainM,
      fwHeaders: fwHeaders,
    );
    return _linkRunner(
      runnerBuild: runnerBuild,
      xcfRoot: xcfRoot,
      runnerObj: runnerObj,
    );
  }

  /// Compile `main.m` → `main.o` via clang. Returns the object file path.
  Future<String> _compileRunnerObj({
    required String runnerBuild,
    required String xcfRoot,
    required String mainM,
    required String fwHeaders,
  }) async {
    final runnerObj = p.join(runnerBuild, 'main.o');
    final subframeworks =
        p.join(iPhoneSdk, 'System', 'Library', 'SubFrameworks');

    logStatus('  [clang] compile main.m → main.o');
    await ProcessRunner.runChecked(
      '/usr/bin/clang',
      [
        '-target',
        'arm64-apple-ios14.0',
        '-isysroot',
        iPhoneSdk,
        '-F',
        p.join(iPhoneSdk, 'System', 'Library', 'Frameworks'),
        '-F',
        subframeworks,
        '-F',
        xcfRoot,
        '-I',
        fwHeaders,
        '-fobjc-arc',
        '-miphoneos-version-min=14.0',
        '-c',
        mainM,
        '-o',
        runnerObj,
      ],
      workingDirectory: kmpProjectRoot,
      inheritStdio: true,
      label: 'clang',
    );

    final runnerObjExists = File(runnerObj).existsSync();
    if (!runnerObjExists) {
      throw XcrossError('[xcross-compose] FAIL: main.o not produced');
    }
    logStatus('  [clang] main.o produced');
    return runnerObj;
  }

  /// Link `main.o` → `Runner` Mach-O via ld64.lld. Returns the binary path.
  Future<String> _linkRunner({
    required String runnerBuild,
    required String xcfRoot,
    required String runnerObj,
  }) async {
    final runnerBin = p.join(runnerBuild, 'Runner');
    final subframeworks =
        p.join(iPhoneSdk, 'System', 'Library', 'SubFrameworks');

    logStatus('  [ld64.lld] link Runner Mach-O');
    await ProcessRunner.runChecked(
      ld64lld,
      [
        '-arch',
        'arm64',
        '-platform_version',
        'ios',
        '14.0',
        _fallbackPlatformVersion,
        '-syslibroot',
        iPhoneSdk,
        '-o',
        runnerBin,
        runnerObj,
        '-F',
        xcfRoot,
        '-F',
        p.join(iPhoneSdk, 'System', 'Library', 'Frameworks'),
        '-F',
        subframeworks,
        '-framework',
        baseName,
        '-framework',
        'UIKit',
        '-framework',
        'Foundation',
        '-lobjc',
        '-lc',
        '-rpath',
        '@executable_path/Frameworks',
      ],
      workingDirectory: kmpProjectRoot,
      inheritStdio: true,
      label: 'ld64.lld',
    );

    final runnerBinExists = File(runnerBin).existsSync();
    if (!runnerBinExists) {
      throw XcrossError('[xcross-compose] FAIL: Runner binary not produced');
    }
    logStatus('  [ld64.lld] Runner binary produced');
    return runnerBin;
  }

  // ---------------------------------------------------------------------------
  // Stage 9: [runnableApp] assemble .app bundle
  // ---------------------------------------------------------------------------

  Future<String> _stage9Assemble(String runnerBin, String frameworkDir) async {
    logStatus('');
    logStatus('== [xcross-compose] Stage 9: assemble $appName.app ==');

    final outApp = p.join(kmpProjectRoot, 'build', 'xtool-ios');
    final appDir = p.join(outApp, '$appName.app');
    final appDirHandle = Directory(appDir);
    final appDirExists = appDirHandle.existsSync();
    if (appDirExists) await appDirHandle.delete(recursive: true);
    await Directory(p.join(appDir, 'Frameworks')).create(recursive: true);

    // Copy Runner binary.
    await File(runnerBin).copy(p.join(appDir, 'Runner'));
    _chmod(p.join(appDir, 'Runner'), '755');

    // Copy <baseName>.framework into Frameworks/ (dynamic; @rpath).
    await _copyDirectory(
        frameworkDir, p.join(appDir, 'Frameworks', '$baseName.framework'));

    // ── Info.plist resolution (B1 fix) ───────────────────────────────────────
    // B1: KMP iosApp Info.plists are PARTIAL (Xcode merges missing keys from
    // xcconfig + GENERATE_INFOPLIST_FILE at build time). Copying them verbatim
    // produces a bundle with NO CFBundleExecutable/CFBundleIdentifier → un-
    // installable. Resolution order:
    //
    //   1. If xtool.yml infoPath is set AND the file contains CFBundleExecutable
    //      → user supplied a complete plist; use it verbatim.
    //   2. Otherwise: SYNTHESISE a complete plist (S5 key set below); then
    //      optionally MERGE any extra keys found in the project's partial
    //      iosApp/Info.plist that are not in the required set (preserves flags
    //      like CADisableMinimumFrameDurationOnPhone). Never pull required keys
    //      from the partial file.
    final infoPlistDest = p.join(appDir, 'Info.plist');

    // Path 1: explicit user-provided complete plist.
    final userPlist = infoPath != null ? File(infoPath!) : null;
    if (userPlist != null && userPlist.existsSync()) {
      final userContent = userPlist.readAsStringSync();
      if (userContent.contains('CFBundleExecutable')) {
        await userPlist.copy(infoPlistDest);
        logStatus('  Info.plist ← (user-provided) ${userPlist.path}');
      } else {
        logWarn(
          '  xtool.yml infoPath set but file lacks CFBundleExecutable — '
          'synthesising a complete plist instead.',
        );
        await File(infoPlistDest)
            .writeAsString(_synthesizeInfoPlist(partialContent: null));
      }
    } else {
      // Path 2: synthesise complete plist, merge extras from partial file.
      String? partialContent;
      for (final candidate in [
        p.join(kmpProjectRoot, 'iosApp', 'iosApp', 'Info.plist'),
        p.join(kmpProjectRoot, 'iosApp', 'Info.plist'),
      ]) {
        final f = File(candidate);
        if (f.existsSync()) {
          partialContent = f.readAsStringSync();
          logStatus('  Info.plist: merging extras from $candidate');
          break;
        }
      }
      logStatus('  Info.plist: synthesising complete install-ready plist');
      await File(infoPlistDest)
          .writeAsString(_synthesizeInfoPlist(partialContent: partialContent));
    }

    // Verify Runner is arm64 Mach-O.
    final fileResult = await ProcessRunner.run(
      'file',
      [p.join(appDir, 'Runner')],
    );
    final fileOut = fileResult.stdout.trim();
    logStatus('  $appName.app/Runner: $fileOut');
    if (!fileOut.contains('arm64') &&
        !fileOut.contains('aarch64') &&
        !fileOut.contains('Mach-O')) {
      logWarn('Runner may not be arm64 Mach-O — check build.');
    }

    logStatus('');
    logStatus(
        '================================================================');
    logStatus(
        '== [xcross-compose] SUCCESS: $appName.app                    ==');
    logStatus(
        '================================================================');
    logStatus('App path: $appDir');

    return appDir;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Build an install-complete Info.plist string for the `.app` bundle.
  ///
  /// S5 key set (always synthesised — never pulled from a partial project
  /// plist):
  ///   CFBundleExecutable, CFBundleIdentifier, CFBundleName,
  ///   CFBundlePackageType, CFBundleShortVersionString, CFBundleVersion,
  ///   CFBundleSupportedPlatforms, MinimumOSVersion, LSRequiresIPhoneOS,
  ///   UIDeviceFamily, UILaunchScreen, UIRequiredDeviceCapabilities.
  ///
  /// If [partialContent] is non-null (a project-side partial plist), any keys
  /// NOT in the required set are extracted and appended (e.g. the KMP example's
  /// `CADisableMinimumFrameDurationOnPhone = true`).
  String _synthesizeInfoPlist({required String? partialContent}) {
    const requiredKeys = {
      'CFBundleExecutable',
      'CFBundleIdentifier',
      'CFBundleName',
      'CFBundlePackageType',
      'CFBundleShortVersionString',
      'CFBundleVersion',
      'CFBundleSupportedPlatforms',
      'MinimumOSVersion',
      'LSRequiresIPhoneOS',
      'UIDeviceFamily',
      'UILaunchScreen',
      'UIRequiredDeviceCapabilities',
    };

    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
          ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
      ..writeln('<plist version="1.0">')
      ..writeln('<dict>')
      ..writeln(
          '  <key>CFBundleExecutable</key><string>${PlistDefaults.executable}</string>')
      ..writeln(
          '  <key>CFBundleIdentifier</key><string>${_xmlEscape(bundleId)}</string>')
      ..writeln(
          '  <key>CFBundleName</key><string>${_xmlEscape(appName)}</string>')
      ..writeln('  <key>CFBundlePackageType</key><string>APPL</string>')
      // Version strings: prefer IosAppConfig (swiftApp/xcconfig path), else defaults.
      ..writeln(
          '  <key>CFBundleShortVersionString</key><string>${iosAppConfig?.marketingVersion ?? '1.0'}</string>')
      ..writeln(
          '  <key>CFBundleVersion</key><string>${iosAppConfig?.currentProjectVersion ?? PlistDefaults.bundleVersion}</string>')
      ..writeln('  <key>CFBundleSupportedPlatforms</key>')
      ..writeln('  <array><string>iPhoneOS</string></array>')
      ..writeln('  <key>MinimumOSVersion</key><string>14.0</string>')
      ..writeln('  <key>LSRequiresIPhoneOS</key><true/>')
      ..writeln('  <key>UIDeviceFamily</key>')
      ..writeln('  <array><integer>1</integer><integer>2</integer></array>')
      ..writeln('  <key>UILaunchScreen</key><dict/>')
      ..writeln('  <key>UIRequiredDeviceCapabilities</key>')
      ..writeln('  <array><string>arm64</string></array>');

    // Merge extras from partial project plist (preserves device/display flags).
    if (partialContent != null) {
      for (final extra in _extractPlistExtras(partialContent, requiredKeys)) {
        buf.writeln(extra);
      }
    }

    buf
      ..writeln('</dict>')
      ..writeln('</plist>');
    return buf.toString();
  }

  /// Extract key-value pairs from [plistContent] whose key is NOT in
  /// [skipKeys]. Returns XML strings ready to embed into a `<dict>` block.
  ///
  /// Handles scalar plist value types (string, integer, real, true, false).
  /// Nested arrays/dicts in the source partial plist are intentionally not
  /// forwarded — those are uncommon in Xcode-generated KMP partial plists
  /// and would require a full XML parser to handle safely.
  List<String> _extractPlistExtras(
      String plistContent, Set<String> skipKeys) {
    final extras = <String>[];
    // Match <key>K</key> followed by a simple scalar value element.
    final re = RegExp(
      '<key>([^<]+)</key>'
      r'(\s*(?:<(?:true|false)/>|<string>[^<]*</string>|<integer>[^<]*</integer>|<real>[^<]*</real>))',
    );
    for (final m in re.allMatches(plistContent)) {
      final key = m.group(1)!.trim();
      if (skipKeys.contains(key)) continue;
      final value = m.group(2)!.trim();
      extras.add('  <key>${_xmlEscape(key)}</key>$value');
    }
    return extras;
  }

  /// Minimal XML escaping for plist key names.
  String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Set permissions via libc `chmod` (FFI) — no subprocess. [mode] is either
  /// the symbolic `+x` (add execute bits to the current mode) or an octal
  /// string such as `755`.
  void _chmod(String path, String mode) {
    if (!posix.isPosixSupported) return;
    if (mode == '+x') {
      final current = File(path).statSync().mode & 0xFFF;
      posix.chmodWithMode(path, current | 0x49); // u+x, g+x, o+x
    } else {
      posix.chmod(path, mode);
    }
  }

  /// Recursively copy [src] directory → [dst] (created if absent).
  Future<void> _copyDirectory(String src, String dst) async {
    await Directory(dst).create(recursive: true);
    await for (final entity in Directory(src).list()) {
      final name = p.basename(entity.path);
      final dstPath = p.join(dst, name);
      if (entity is Directory) {
        await _copyDirectory(entity.path, dstPath);
      } else if (entity is Link) {
        final target = await entity.target();
        final link = Link(dstPath);
        final linkExists = link.existsSync();
        if (!linkExists) await link.create(target);
      } else if (entity is File) {
        await entity.copy(dstPath);
      }
    }
  }
}
