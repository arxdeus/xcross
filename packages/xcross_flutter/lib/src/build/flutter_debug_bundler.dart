import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:frontend_server_kit/frontend_server_kit.dart';
import 'package:path/path.dart' as p;
import 'package:standard_message_codec/standard_message_codec.dart';
import 'package:xcross_flutter/src/build/ios_engine_cache.dart';
import 'package:xcross_flutter/src/constants.dart';
import 'package:xcross_flutter/src/errors.dart';
import 'package:xcross_flutter/src/models/pubspec_info.dart';

/// Assembles `App.framework` (debug/JIT mode) for a Flutter iOS app without
/// invoking `xcrun` or `flutter_tools.snapshot assemble`.
///
/// Cross-platform path for hosts where `xcrun` is unavailable.
///
/// Pipeline:
///   1. Download iOS engine artifacts via [IosEngineCache] if missing.
///   2. Run `frontend_server` → `app.dill` (Dart kernel for JIT).
///   3. Bundle `flutter_assets/` (kernel blob, snapshot data, manifests).
///   4. Build App stub Mach-O dylib via clang + ld64.lld from PATH.
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

  /// Empty zlib stream: `zlib.compress(b'')` in Python.
  /// CMF=0x78 FLG=0x9c, empty deflate block (BFINAL=1 BTYPE=0, zero length),
  /// Adler-32 of empty input = 0x00000001 big-endian.
  static const _emptyZlibBytes = [
    0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01, //
  ];

  /// Build `App.framework` inside [outputDir]. Returns the framework path.
  Future<String> build() async {
    final engineCache = IosEngineCache(flutterRoot: flutterRoot);
    await Log.logStep(
      'Fetching Flutter engine artifacts',
      engineCache.ensureArtifactsAvailable,
    );

    Log.logTrace('resolving iOS debug toolchain');
    final toolchain = await _resolveToolchain();

    Log.logTrace('preparing App.framework output');
    await Directory(outputDir).create(recursive: true);

    final appFramework = p.join(outputDir, 'App.framework');
    final assetsDir = p.join(appFramework, 'flutter_assets');

    final appDir = Directory(appFramework);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
    await Directory(assetsDir).create(recursive: true);

    final appDill = await _runKernelSnapshot(engineCache);
    final pubspec = PubspecInfo.loadSync(projectRoot);

    await Log.logStep('Bundling assets', () async {
      await _copyDataAssets(assetsDir, engineCache, appDill);
      final assetManifest = await _copyPubspecAssets(assetsDir, pubspec);
      final fonts = await _copyFonts(assetsDir, pubspec);
      _writeManifests(assetsDir, assetManifest, fonts);
    });

    await _buildAppStub(appFramework, toolchain);

    Log.logTrace('writing App.framework Info.plist');
    _writeAppFrameworkInfoPlist(appFramework);

    return appFramework;
  }

  Future<String> _runKernelSnapshot(IosEngineCache engineCache) async {
    final snapshot = engineCache.frontendServer;
    final dartSdkBin = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin');

    // AOT snapshots run via `dartaotruntime`; non-AOT via `dart`.
    final isAot = p.basename(snapshot).contains('_aot');
    final runtimeName = isAot ? 'dartaotruntime' : 'dart';
    final runtime = p.join(
      dartSdkBin,
      ProcessRunner.hostExecutableName(runtimeName),
    );

    _validateKernelDependencies(snapshot, runtime, runtimeName, engineCache);

    final scratch = p.join(
      projectRoot,
      'build',
      'xcross-flutter-debug',
      '.kernel',
    );
    final scratchDir = Directory(scratch);
    if (scratchDir.existsSync()) await scratchDir.delete(recursive: true);
    await scratchDir.create(recursive: true);

    final outputDill = p.join(scratch, 'app.dill');
    final packageConfig = p.join(
      projectRoot,
      '.dart_tool',
      'package_config.json',
    );
    final packageConfigExists = File(packageConfig).existsSync();
    if (!packageConfigExists) {
      throw FlutterBuildError(
        'FlutterDebugBundler: package_config.json missing at $packageConfig; '
        'run `dart pub get` first.',
      );
    }

    // Resolve entrypoint — join with projectRoot when relative.
    final resolvedEntrypoint = p.isAbsolute(entrypoint)
        ? entrypoint
        : p.join(projectRoot, entrypoint);

    // Compile under the entrypoint's `package:` URI when it has one, as
    // flutter_tools does: this is what sets the kernel's `Library.importUri`,
    // and that is what a `package:` breakpoint matches. See [PackageUris].
    final packageUris = await PackageUris.load(packageConfig);
    final entrypointArg =
        packageUris?.toCompilerUri(resolvedEntrypoint) ?? resolvedEntrypoint;

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
      entrypointArg,
    ];

    await Log.logStep(
      'Compiling Dart kernel',
      () => ProcessRunner.runChecked(
        runtime,
        args,
        workingDirectory: projectRoot,
        // Inheriting fd1 while a spinner animates shreds the line; capture
        // instead (the stderr is folded into the thrown error either way).
        inheritStdio: Log.isVerbose,
        label: 'frontend_server',
      ),
    );

    final outputDillExists = File(outputDill).existsSync();
    if (!outputDillExists) {
      throw FlutterBuildError(
        'FlutterDebugBundler: kernel snapshot did not produce $outputDill',
      );
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
    final snapshotExists = File(snapshot).existsSync();
    if (!snapshotExists) {
      throw FlutterBuildError(
        'FlutterDebugBundler: frontend_server snapshot missing at $snapshot.\n'
        'Run `<FLUTTER_ROOT>/bin/dart --version` once to materialize.',
      );
    }
    final runtimeExists = File(runtime).existsSync();
    if (!runtimeExists) {
      throw FlutterBuildError(
        'FlutterDebugBundler: $runtimeName not at $runtime',
      );
    }
    final platformDillExists = File(
      p.join(engineCache.patchedSdkRoot, 'platform_strong.dill'),
    ).existsSync();
    if (!platformDillExists) {
      throw FlutterBuildError(
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
    await File(
      engineCache.vmSnapshotData,
    ).copy(p.join(assetsDir, 'vm_snapshot_data'));
    await File(
      engineCache.isolateSnapshotData,
    ).copy(p.join(assetsDir, 'isolate_snapshot_data'));
  }

  /// Copy `flutter: assets:` entries into `flutter_assets/`, preserving their
  /// pubspec-relative paths, and build the `AssetManifest` key → variants map.
  ///
  /// ponytail: no density-variant grouping (2x/3x sibling dirs) — every asset
  /// resolves to exactly its declared path. Add `_AssetDirectoryCache`-style
  /// variant scanning (see flutter_tools' asset.dart) if that's ever needed.
  Future<Map<String, List<String>>> _copyPubspecAssets(
    String assetsDir,
    PubspecInfo pubspec,
  ) async {
    final manifest = <String, List<String>>{};
    for (final entry in pubspec.assets) {
      if (entry.endsWith('/')) {
        final dir = Directory(p.join(projectRoot, entry));
        if (!dir.existsSync()) {
          throw FlutterBuildError(
            'pubspec.yaml: asset directory not found: $entry',
          );
        }
        // Non-recursive, matching flutter_tools' folder-entry semantics.
        for (final file in dir.listSync().whereType<File>()) {
          final key = '$entry${p.basename(file.path)}';
          await _copyAssetFile(file.path, assetsDir, key);
          manifest[key] = [key];
        }
      } else {
        final src = p.join(projectRoot, entry);
        final srcExists = File(src).existsSync();
        if (!srcExists) {
          throw FlutterBuildError('pubspec.yaml: asset not found: $entry');
        }
        await _copyAssetFile(src, assetsDir, entry);
        manifest[entry] = [entry];
      }
    }
    return manifest;
  }

  /// Copy `MaterialIcons-Regular.otf` (if material design is used) and any
  /// `flutter: fonts:` families, returning `FontManifest.json` descriptors.
  Future<List<Map<String, Object?>>> _copyFonts(
    String assetsDir,
    PubspecInfo pubspec,
  ) async {
    final fonts = <Map<String, Object?>>[];

    if (pubspec.usesMaterialDesign) {
      final src = p.join(
        flutterRoot,
        'bin',
        'cache',
        'artifacts',
        'material_fonts',
        'MaterialIcons-Regular.otf',
      );
      final srcExists = File(src).existsSync();
      if (srcExists) {
        await _copyAssetFile(src, assetsDir, 'fonts/MaterialIcons-Regular.otf');
        fonts.add(const {
          'family': 'MaterialIcons',
          'fonts': [
            {'asset': 'fonts/MaterialIcons-Regular.otf'},
          ],
        });
      }
    }

    for (final family in pubspec.fonts) {
      for (final font in family.fonts) {
        final src = p.join(projectRoot, font.asset);
        final srcExists = File(src).existsSync();
        if (!srcExists) {
          throw FlutterBuildError(
            'pubspec.yaml: font asset not found: ${font.asset}',
          );
        }
        await _copyAssetFile(src, assetsDir, font.asset);
      }
      fonts.add(family.descriptor);
    }

    return fonts;
  }

  /// Copy [src] to `assetsDir/key`, creating parent directories as needed.
  Future<void> _copyAssetFile(String src, String assetsDir, String key) async {
    final dst = p.join(assetsDir, key);
    await Directory(p.dirname(dst)).create(recursive: true);
    await File(src).copy(dst);
  }

  void _writeManifests(
    String assetsDir,
    Map<String, List<String>> assetManifest,
    List<Map<String, Object?>> fonts,
  ) {
    // AssetManifest.bin — the exact binary shape flutter_tools produces:
    // Map<String, List<{"asset": path}>>, StandardMessageCodec-encoded.
    final binMessage = <String, Object?>{
      for (final entry in assetManifest.entries)
        entry.key: [
          for (final variant in entry.value) {'asset': variant},
        ],
    };
    final binBytes = const StandardMessageCodec().encodeMessage(binMessage);
    File(p.join(assetsDir, 'AssetManifest.bin')).writeAsBytesSync(
      binBytes?.buffer.asUint8List(0, binBytes.lengthInBytes) ?? Uint8List(0),
    );

    // AssetManifest.json — legacy JSON variant still read by some plugins.
    File(
      p.join(assetsDir, 'AssetManifest.json'),
    ).writeAsStringSync(jsonEncode(assetManifest));

    // FontManifest.json — registers custom + Material fonts with the engine.
    File(
      p.join(assetsDir, 'FontManifest.json'),
    ).writeAsStringSync(jsonEncode(fonts));

    // NativeAssetsManifest.json — minimal valid shape expected by the engine.
    File(
      p.join(assetsDir, 'NativeAssetsManifest.json'),
    ).writeAsStringSync('{"format-version":[1,0,0],"native-assets":{}}');

    // NOTICES.Z — empty zlib stream (LicensePage handles empty content fine).
    File(p.join(assetsDir, 'NOTICES.Z')).writeAsBytesSync(_emptyZlibBytes);
  }

  Future<Toolchain> _resolveToolchain() async {
    final darwin = DarwinSdk.current();
    if (darwin == null) {
      throw FlutterBuildError(
        'FlutterDebugBundler: no usable toolchain. No Darwin SDK found.\n'
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>` first.',
      );
    }
    return Toolchain(
      clang: await ProcessRunner.locateTool(
        Platform.isWindows ? 'clang.exe' : 'clang',
      ),
      iosSDK: darwin.iPhoneOSSdk(),
      lldToolsetBin: p.dirname(await DarwinSdk.resolveLd64Lld(darwin)),
    );
  }

  Future<void> _buildAppStub(String appFramework, Toolchain toolchain) =>
      Log.logStep('Building App.framework', () async {
        final tmp = await Directory.systemTemp.createTemp(
          'xcross-flutter-stub-',
        );
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
          inheritStdio: Log.isVerbose,
          label: 'clang',
        );

        final outputBinaryExists = File(outputBinary).existsSync();
        if (!outputBinaryExists) {
          throw FlutterBuildError(
            'FlutterDebugBundler: clang did not produce $outputBinary',
          );
        }

        await tmp.delete(recursive: true);
      });

  /// Build the clang argument list for the App stub dylib.
  static List<String> _appStubClangArgs({
    required Toolchain toolchain,
    required String stubSource,
    required String outputBinary,
  }) {
    return <String>[
      '-fuse-ld=lld',
      '-B',
      toolchain.lldToolsetBin,
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
    const plist =
        '<?xml version="1.0" encoding="UTF-8"?>\n'
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
class Toolchain {
  const Toolchain({
    required this.clang,
    required this.iosSDK,
    required this.lldToolsetBin,
  });

  final String clang;
  final String iosSDK;

  /// Directory containing the PATH-resolved `ld64.lld`.
  final String lldToolsetBin;
}
