import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:frontend_server_kit/frontend_server_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:standard_message_codec/standard_message_codec.dart';
import 'package:xcross/src/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/flutter/build/internal/kernel_compiler.dart';
import 'package:xcross/src/flutter/build/internal/toolchain.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/pubspec_info.dart';
import 'package:xcross/src/package_config_resolver.dart';

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
final class FlutterDebugBundler {
  final String projectRoot;
  final String flutterRoot;
  final String outputDir;
  final IosDeploymentTarget deploymentTarget;

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
    required this.deploymentTarget,
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
    final compiler = _resolveKernelCompiler(engineCache);
    _validateKernelDependencies(compiler, engineCache);

    final outputDill = await _prepareKernelScratch();
    final packageConfig = await PackageConfigResolver.require(projectRoot);

    final entrypointArg = await _resolveEntrypointArg(packageConfig);

    // Federated plugins install their Dart-side implementation from here.
    // Without it the app boots but the first plugin call throws
    // "a platform implementation has not been set", usually before runApp,
    // which reaches the device as a black screen.
    final registrant = await DartPluginRegistrant.generate(
      projectRoot: projectRoot,
      plugins: await PluginDiscovery.discover(projectRoot),
      entrypointUri: entrypointArg,
    );
    final packageUris = await PackageUris.load(packageConfig);
    final registrantUri = registrant == null
        ? null
        : dartPluginRegistrantUri(registrant, packageUris);
    if (registrantUri != null) {
      Log.logTrace('dart plugin registrant: $registrantUri');
    }

    final args = _frontendServerArgs(
      compiler: compiler,
      engineCache: engineCache,
      packageConfig: packageConfig,
      outputDill: outputDill,
      entrypointArg: entrypointArg,
      dartPluginRegistrantUri: registrantUri,
    );

    await Log.logStep(
      'Compiling Dart kernel',
      () => ProcessRunner.runChecked(
        compiler.runtime,
        args,
        workingDirectory: projectRoot,
        // Inheriting fd1 while a spinner animates shreds the line; capture
        // instead (the stderr is folded into the thrown error either way).
        inheritStdio: Log.isVerbose,
        label: 'frontend_server',
      ),
    );

    if (!File(outputDill).existsSync()) {
      throw FlutterBuildError(
        'FlutterDebugBundler: kernel snapshot did not produce $outputDill',
      );
    }
    return outputDill;
  }

  /// The frontend_server snapshot plus the Dart runtime that can execute it.
  /// AOT snapshots run via `dartaotruntime`; non-AOT via `dart`.
  KernelCompiler _resolveKernelCompiler(IosEngineCache engineCache) {
    final snapshot = engineCache.frontendServer;
    final isAot = p.basename(snapshot).contains('_aot');
    final runtimeName = isAot ? 'dartaotruntime' : 'dart';
    return KernelCompiler(
      snapshot: snapshot,
      isAot: isAot,
      runtimeName: runtimeName,
      runtime: p.join(
        flutterRoot,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        ProcessRunner.hostExecutableName(runtimeName),
      ),
    );
  }

  /// Guard that all prerequisites for the kernel snapshot step exist.
  void _validateKernelDependencies(
    KernelCompiler compiler,
    IosEngineCache engineCache,
  ) {
    if (!File(compiler.snapshot).existsSync()) {
      throw FlutterBuildError(
        'FlutterDebugBundler: frontend_server snapshot missing at '
        '${compiler.snapshot}.\n'
        'Run `<FLUTTER_ROOT>/bin/dart --version` once to materialize.',
      );
    }
    if (!File(compiler.runtime).existsSync()) {
      throw FlutterBuildError(
        'FlutterDebugBundler: ${compiler.runtimeName} not at '
        '${compiler.runtime}',
      );
    }
    final platformDill = p.join(
      engineCache.patchedSdkRoot,
      'platform_strong.dill',
    );
    if (!File(platformDill).existsSync()) {
      throw FlutterBuildError(
        'FlutterDebugBundler: ${engineCache.patchedSdkRoot} is missing\n'
        'platform_strong.dill. Try deleting '
        '`bin/cache/artifacts/engine/common/` and rerunning.',
      );
    }
  }

  /// Recreate the kernel scratch directory and return its `app.dill` path.
  Future<String> _prepareKernelScratch() async {
    final scratch = Directory(
      p.join(projectRoot, 'build', 'xcross-flutter-debug', '.kernel'),
    );
    if (scratch.existsSync()) await scratch.delete(recursive: true);
    await scratch.create(recursive: true);
    return p.join(scratch.path, 'app.dill');
  }

  /// The entrypoint as frontend_server should see it.
  ///
  /// Compile under the entrypoint's `package:` URI when it has one, as
  /// flutter_tools does: this is what sets the kernel's `Library.importUri`,
  /// and that is what a `package:` breakpoint matches. See [PackageUris].
  Future<String> _resolveEntrypointArg(String packageConfig) async {
    final resolved = p.isAbsolute(entrypoint)
        ? entrypoint
        : p.join(projectRoot, entrypoint);
    final packageUris = await PackageUris.load(packageConfig);
    return packageUris?.toCompilerUri(resolved) ?? resolved;
  }

  /// ORDER MATTERS: dartaotruntime takes <snapshot> as its first arg, so
  /// `dart`'s --disable-dart-dev must precede it. --sdk-root needs its
  /// trailing slash: frontend_server resolves platform_strong.dill by string
  /// concatenation. The -Ddart.* / --track-widget-creation quartet is what
  /// makes the kernel hot-reloadable.
  ///
  /// The registrant [path] as the compiler and the VM must see it: a URI,
  /// never a bare filesystem path.
  ///
  /// At runtime the engine compares `-Dflutter.dart_plugin_registrant` against
  /// the kernel library's `importUri`; a bare path matches no library, so the
  /// registrant is never run and every federated plugin stays unregistered —
  /// with no error anywhere, which is exactly how this manifests as a blank
  /// screen. The generated file sits in `.dart_tool/flutter_build/`, outside
  /// any package `lib/`, so this is the `file://` form in practice; the
  /// `package:` branch covers a project that relocates it inside a package.
  @visibleForTesting
  static String dartPluginRegistrantUri(String path, PackageUris? packageUris) {
    final fileUri = Uri.file(path);
    return packageUris?.toPackageUri(fileUri)?.toString() ?? fileUri.toString();
  }

  List<String> _frontendServerArgs({
    required KernelCompiler compiler,
    required IosEngineCache engineCache,
    required String packageConfig,
    required String outputDill,
    required String entrypointArg,
    String? dartPluginRegistrantUri,
  }) => <String>[
    if (!compiler.isAot) '--disable-dart-dev',
    compiler.snapshot,
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
    // All three go together: the generated registrant, the flutter library
    // that calls it, and the define naming which library to look in. Passing
    // fewer means the VM never runs the registrant.
    if (dartPluginRegistrantUri != null) ...[
      '--source',
      dartPluginRegistrantUri,
      '--source',
      'package:flutter/src/dart_plugin_registrant.dart',
      '-Dflutter.dart_plugin_registrant=$dartPluginRegistrantUri',
    ],
    entrypointArg,
  ];

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
      clang: await DarwinSdk.resolveDarwinClang(darwin),
      iosSdk: darwin.iPhoneOSSdk(),
      linker: await DarwinSdk.resolveLd64Lld(darwin),
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
        final args = appStubClangArgs(
          toolchain: toolchain,
          stubSource: stubSource,
          outputBinary: outputBinary,
          deploymentTarget: deploymentTarget,
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
  @visibleForTesting
  static List<String> appStubClangArgs({
    required Toolchain toolchain,
    required String stubSource,
    required String outputBinary,
    required IosDeploymentTarget deploymentTarget,
  }) {
    return <String>[
      '-fuse-ld=lld',
      // By path, not by -B: a bare -B lets clang link with whichever
      // ld64.lld happens to sit in that directory, and the Swift toolchain
      // ships one that cannot link Mach-O for iOS.
      '--ld-path=${toolchain.linker}',
      '--target=${deploymentTarget.buildTriple}',
      '-arch',
      'arm64',
      '-miphoneos-version-min=${deploymentTarget.version}',
      '-isysroot',
      toolchain.iosSdk,
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
    File(
      p.join(appFramework, 'Info.plist'),
    ).writeAsStringSync(appFrameworkInfoPlist(deploymentTarget));
  }

  @visibleForTesting
  static String appFrameworkInfoPlist(IosDeploymentTarget deploymentTarget) {
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
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
        '\t<string>${deploymentTarget.version}</string>\n'
        '</dict>\n'
        '</plist>\n';
  }
}
