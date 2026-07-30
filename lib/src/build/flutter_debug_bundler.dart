import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:xcross/src/build/ios_engine_cache.dart';
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/models/config/pubspec_info.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/xtool/darwin_sdk.dart';

/// Assembles `App.framework` (debug/JIT mode) for a Flutter iOS app without
/// invoking `xcrun` or `flutter_tools.snapshot assemble`.
///
/// Cross-platform path used on Linux where `xcrun` is unavailable.
///
/// Pipeline:
///   1. Download iOS engine artifacts via [IosEngineCache] if missing.
///   2. Run `frontend_server` → `app.dill` (Dart kernel for JIT).
///   3. Bundle `flutter_assets/` (kernel blob, snapshot data, manifests).
///   4. Build App stub Mach-O dylib via clang + xtool's ld64.lld.
///   5. Write `App.framework/Info.plist`.
///
class FlutterDebugBundler {
  final String projectRoot;
  final String flutterRoot;
  final String outputDir;

  /// Dart entrypoint to compile (default: `lib/main.dart`).
  final String entrypoint;

  /// `KEY=VALUE` dart-define strings forwarded to frontend_server as
  /// `-D<KEY=VALUE>` flags alongside the built-in vm.profile/vm.product flags.
  final List<String> dartDefines;

  /// `--flavor` value. When set, forwarded to frontend_server as
  /// `-DFLUTTER_APP_FLAVOR=<flavor>`, mirroring how `package:flutter/services`
  /// reads `appFlavor` via `String.fromEnvironment('FLUTTER_APP_FLAVOR')`.
  /// Skipped if [dartDefines] already contains an explicit
  /// `FLUTTER_APP_FLAVOR=` define (explicit define wins).
  final String? flavor;

  FlutterDebugBundler({
    required this.projectRoot,
    required this.flutterRoot,
    required this.outputDir,
    this.entrypoint = 'lib/main.dart',
    this.dartDefines = const [],
    this.flavor,
  });

  /// StandardMessageCodec empty map: tag 0x0d (Map) + 4-byte LE length 0.
  static const _emptyAssetManifestBytes = [0x0d, 0x00, 0x00, 0x00, 0x00];

  /// Empty zlib stream: `zlib.compress(b'')` in Python.
  /// CMF=0x78 FLG=0x9c, empty deflate block (BFINAL=1 BTYPE=0, zero length),
  /// Adler-32 of empty input = 0x00000001 big-endian.
  static const _emptyZlibBytes = [
    0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01, //
  ];

  /// Build `App.framework` inside [outputDir]. Returns the framework path.
  Future<String> build() async {
    final engineCache = IosEngineCache(flutterRoot: flutterRoot);
    await logStep(
      'Fetching Flutter engine artifacts',
      engineCache.ensureArtifactsAvailable,
    );

    logTrace('resolving iOS debug toolchain');
    final toolchain = await _resolveToolchain();

    logTrace('preparing App.framework output');
    await Directory(outputDir).create(recursive: true);

    final appFramework = p.join(outputDir, 'App.framework');
    final assetsDir = p.join(appFramework, 'flutter_assets');

    final appDir = Directory(appFramework);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
    await Directory(assetsDir).create(recursive: true);

    final appDill = await _runKernelSnapshot(engineCache);

    await logStep('Bundling assets', () async {
      await _copyDataAssets(assetsDir, engineCache, appDill);
      await _copyMaterialFonts(assetsDir);
      _writeManifests(assetsDir);
    });

    await _buildAppStub(appFramework, toolchain);

    logTrace('writing App.framework Info.plist');
    _writeAppFrameworkInfoPlist(appFramework);

    return appFramework;
  }

  Future<String> _runKernelSnapshot(IosEngineCache engineCache) async {
    final snapshot = engineCache.frontendServer;
    final dartSdkBin = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin');

    // AOT snapshots run via `dartaotruntime`; non-AOT via `dart`.
    final isAot = p.basename(snapshot).contains('_aot');
    final runtimeName = isAot ? 'dartaotruntime' : 'dart';
    final runtime = p.join(dartSdkBin, runtimeName);

    _validateKernelDependencies(snapshot, runtime, runtimeName, engineCache);

    final scratch =
        p.join(projectRoot, 'build', 'xtool-flutter-debug', '.kernel');
    final scratchDir = Directory(scratch);
    if (scratchDir.existsSync()) await scratchDir.delete(recursive: true);
    await scratchDir.create(recursive: true);

    final outputDill = p.join(scratch, 'app.dill');
    final packageConfig =
        p.join(projectRoot, '.dart_tool', 'package_config.json');
    if (!File(packageConfig).existsSync()) {
      throw XcrossError(
        'FlutterDebugBundler: package_config.json missing at $packageConfig; '
        'run `dart pub get` first.',
      );
    }

    // Resolve entrypoint — join with projectRoot when relative.
    final resolvedEntrypoint =
        p.isAbsolute(entrypoint) ? entrypoint : p.join(projectRoot, entrypoint);

    // ORDER MATTERS: dartaotruntime takes <snapshot> as its first arg, so
    // `dart`'s --disable-dart-dev must precede it. --sdk-root needs its
    // trailing slash: frontend_server resolves platform_strong.dill by string
    // concatenation. The -Ddart.* / --track-widget-creation quartet is what
    // makes the kernel hot-reloadable.
    final args = <String>[
      if (!isAot) '--disable-dart-dev',
      snapshot,
      '--sdk-root', '${engineCache.patchedSdkRoot}/',
      '--target=flutter',
      '--no-print-incremental-dependencies',
      '-Ddart.developer.serviceExtensionStream.enabled=true',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=false',
      '--track-widget-creation',
      '--packages', packageConfig,
      '--output-dill', outputDill,
      // User-supplied dart-defines forwarded as -D<KEY=VALUE>.
      for (final define in dartDefines) '-D$define',
      // --flavor → FLUTTER_APP_FLAVOR dart-define, unless already set
      // explicitly above (explicit define wins).
      if (flavor != null &&
          !dartDefines.any((d) => d.startsWith('FLUTTER_APP_FLAVOR=')))
        '-DFLUTTER_APP_FLAVOR=$flavor',
      resolvedEntrypoint,
    ];

    await logStep(
      'Compiling Dart kernel',
      () => ProcessRunner.runChecked(
        runtime,
        args,
        workingDirectory: projectRoot,
        // Inheriting fd1 while a spinner animates shreds the line; capture
        // instead (the stderr is folded into the thrown error either way).
        inheritStdio: isVerbose,
        label: 'frontend_server',
      ),
    );

    if (!File(outputDill).existsSync()) {
      throw XcrossError(
          'FlutterDebugBundler: kernel snapshot did not produce $outputDill');
    }
    return outputDill;
  }

  /// Guard that all prerequisites for the kernel snapshot step exist.
  void _validateKernelDependencies(
    String snapshot,
    String runtime,
    String runtimeName,
    IosEngineCache engineCache,
  ) {
    if (!File(snapshot).existsSync()) {
      throw XcrossError(
        'FlutterDebugBundler: frontend_server snapshot missing at $snapshot.\n'
        'Run `<FLUTTER_ROOT>/bin/dart --version` once to materialize.',
      );
    }
    if (!File(runtime).existsSync()) {
      throw XcrossError('FlutterDebugBundler: $runtimeName not at $runtime');
    }
    if (!File(p.join(engineCache.patchedSdkRoot, 'platform_strong.dill'))
        .existsSync()) {
      throw XcrossError(
        'FlutterDebugBundler: ${engineCache.patchedSdkRoot} is missing\n'
        'platform_strong.dill. Try deleting '
        '`bin/cache/artifacts/engine/common/` and rerunning.',
      );
    }
  }

  Future<void> _copyDataAssets(
    String assetsDir,
    IosEngineCache engineCache,
    String appDill,
  ) async {
    // kernel_blob.bin — Dart kernel for JIT execution.
    await File(appDill).copy(p.join(assetsDir, 'kernel_blob.bin'));
    // Snapshot data files (name remap: .bin suffix dropped, stem changed).
    await File(engineCache.vmSnapshotData)
        .copy(p.join(assetsDir, 'vm_snapshot_data'));
    await File(engineCache.isolateSnapshotData)
        .copy(p.join(assetsDir, 'isolate_snapshot_data'));
  }

  /// Copy `MaterialIcons-Regular.otf` when the project uses material design.
  Future<void> _copyMaterialFonts(String assetsDir) async {
    if (!File(p.join(projectRoot, 'pubspec.yaml')).existsSync()) return;
    if (!PubspecInfo.loadSync(projectRoot).usesMaterialDesign) return;

    final fontsDir = p.join(assetsDir, 'fonts');
    await Directory(fontsDir).create(recursive: true);

    final src = p.join(flutterRoot, 'bin', 'cache', 'artifacts',
        'material_fonts', 'MaterialIcons-Regular.otf');
    if (!File(src).existsSync()) return;

    final dst = p.join(fontsDir, 'MaterialIcons-Regular.otf');
    if (File(dst).existsSync()) await File(dst).delete();
    await File(src).copy(dst);
  }

  void _writeManifests(String assetsDir) {
    // AssetManifest.bin — StandardMessageCodec empty map (5 bytes).
    File(p.join(assetsDir, 'AssetManifest.bin'))
        .writeAsBytesSync(_emptyAssetManifestBytes);

    // AssetManifest.json — legacy JSON variant still read by some plugins.
    File(p.join(assetsDir, 'AssetManifest.json')).writeAsStringSync('{}');

    // FontManifest.json — empty array (no custom fonts registered).
    File(p.join(assetsDir, 'FontManifest.json')).writeAsStringSync('[]');

    // NativeAssetsManifest.json — minimal valid shape expected by the engine.
    File(p.join(assetsDir, 'NativeAssetsManifest.json'))
        .writeAsStringSync('{"format-version":[1,0,0],"native-assets":{}}');

    // NOTICES.Z — empty zlib stream (LicensePage handles empty content fine).
    File(p.join(assetsDir, 'NOTICES.Z')).writeAsBytesSync(_emptyZlibBytes);
  }

  Future<_Toolchain> _resolveToolchain() async {
    final darwin = DarwinSdk.current();
    if (darwin != null) {
      return _Toolchain(
        clang: await locateTool('clang'),
        iosSDK: darwin.iPhoneOSSdk(),
        lldToolsetBin: p.join(darwin.bundle, 'toolset', 'bin'),
      );
    }
    // Linux without xtool Darwin SDK — cannot proceed.
    throw XcrossError(
      'FlutterDebugBundler: no usable toolchain. xtool Darwin SDK not found.\n'
      'Install with `xtool sdk install <Xcode.xip|Xcode.app>` first.',
    );
  }

  Future<void> _buildAppStub(String appFramework, _Toolchain toolchain) =>
      logStep('Building App.framework', () async {
        final tmp =
            await Directory.systemTemp.createTemp('xtool-flutter-stub-');
        final stubSource = p.join(tmp.path, 'debug_app.c');
        // Exact stub content emitted by flutter_tools.
        await File(stubSource).writeAsString('static const int Moo = 88;\n');

        await Directory(appFramework).create(recursive: true);
        final outputBinary = p.join(appFramework, 'App');

        // Flags mirror flutter_tools `_createStubAppFramework`.
        final args = _appStubClangArgs(
          toolchain: toolchain,
          stubSource: stubSource,
          outputBinary: outputBinary,
        );

        await ProcessRunner.runChecked(
          toolchain.clang,
          args,
          inheritStdio: isVerbose,
          label: 'clang',
        );

        if (!File(outputBinary).existsSync()) {
          throw XcrossError(
              'FlutterDebugBundler: clang did not produce $outputBinary');
        }

        await tmp.delete(recursive: true);
      });

  /// Build the clang argument list for the App stub dylib.
  static List<String> _appStubClangArgs({
    required _Toolchain toolchain,
    required String stubSource,
    required String outputBinary,
  }) {
    return <String>[
      if (toolchain.lldToolsetBin != null) ...[
        '-fuse-ld=lld',
        '-B',
        toolchain.lldToolsetBin!,
      ],
      '--target=${IosDeploymentConstants.buildTriple}',
      '-arch',
      'arm64',
      '-miphoneos-version-min=${IosDeploymentConstants.minDeploymentTarget}',
      '-isysroot',
      toolchain.iosSDK,
      '-x',
      'c',
      stubSource,
      '-dynamiclib',
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      '@executable_path/Frameworks',
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      '@loader_path/Frameworks',
      '-fapplication-extension',
      '-install_name',
      '@rpath/App.framework/App',
      '-o',
      outputBinary,
    ];
  }

  void _writeAppFrameworkInfoPlist(String appFramework) {
    const plist = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
        ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        '<dict>\n'
        '\t<key>CFBundleDevelopmentRegion</key>\n'
        '\t<string>en</string>\n'
        '\t<key>CFBundleExecutable</key>\n'
        '\t<string>App</string>\n'
        '\t<key>CFBundleIdentifier</key>\n'
        '\t<string>io.flutter.flutter.app</string>\n'
        '\t<key>CFBundleInfoDictionaryVersion</key>\n'
        '\t<string>6.0</string>\n'
        '\t<key>CFBundleName</key>\n'
        '\t<string>App</string>\n'
        '\t<key>CFBundlePackageType</key>\n'
        '\t<string>FMWK</string>\n'
        '\t<key>CFBundleShortVersionString</key>\n'
        '\t<string>1.0</string>\n'
        '\t<key>CFBundleSignature</key>\n'
        '\t<string>????</string>\n'
        '\t<key>CFBundleVersion</key>\n'
        '\t<string>1.0</string>\n'
        '\t<key>${IosDeploymentConstants.minimumOsVersionKey}</key>\n'
        '\t<string>${IosDeploymentConstants.minDeploymentTarget}</string>\n'
        '</dict>\n'
        '</plist>\n';
    File(p.join(appFramework, 'Info.plist')).writeAsStringSync(plist);
  }
}

/// Resolved toolchain for the App.framework stub build.
class _Toolchain {
  const _Toolchain({
    required this.clang,
    required this.iosSDK,
    this.lldToolsetBin,
  });

  final String clang;
  final String iosSDK;

  /// Path to `toolset/bin/` containing `ld64.lld`. Null on macOS where the
  /// host clang's default linker handles Mach-O.
  final String? lldToolsetBin;
}
