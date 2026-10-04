import 'package:cli_kit/cli_kit_shared.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/internal/toolchain.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/shared/flutter/constants.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_assets_compiler.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_kernel_compiler.dart';

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
final class FlutterDebugBundler<T extends PlatformHostInterface> {
  final FlutterBuildRuntime<T> runtime;
  final FlutterKernelCompiler<T> kernel;
  final FlutterAssetsCompiler assets;
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
    required this.runtime,
    required this.kernel,
    required this.assets,
    required this.projectRoot,
    required this.flutterRoot,
    required this.outputDir,
    required this.deploymentTarget,
    this.entrypoint = 'lib/main.dart',
    this.dartDefines = const [],
    this.flavor,
  });

  /// Build `App.framework` inside [outputDir]. Returns the framework path.
  Future<String> build() async {
    final engineCache = runtime.engineCache(flutterRoot);
    await runtime.runner.log.logStep(
      'Fetching Flutter engine artifacts',
      engineCache.ensureArtifactsAvailable,
    );

    runtime.runner.log.logTrace('resolving iOS debug toolchain');
    final toolchain = await _resolveToolchain();

    runtime.runner.log.logTrace('preparing App.framework output');
    await runtime.host.fileSystem.directory(outputDir).create(recursive: true);

    final appFramework = p.join(outputDir, 'App.framework');
    final assetsDir = p.join(appFramework, 'flutter_assets');

    final appDir = runtime.host.fileSystem.directory(appFramework);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
    await runtime.host.fileSystem.directory(assetsDir).create(recursive: true);

    final appDill = await kernel.compile(engineCache);
    final pubspec = runtime.pubspecs.loadSync(projectRoot);

    await runtime.runner.log.logStep(
      'Bundling assets',
      () => assets.bundle(
        assetsDir: assetsDir,
        appDill: appDill,
        vmSnapshotData: engineCache.vmSnapshotData,
        isolateSnapshotData: engineCache.isolateSnapshotData,
        pubspec: pubspec,
      ),
    );

    await buildAppStub(appFramework, toolchain);

    runtime.runner.log.logTrace('writing App.framework Info.plist');
    _writeAppFrameworkInfoPlist(appFramework);

    return appFramework;
  }

  Future<Toolchain> _resolveToolchain() async {
    final darwin = runtime.sdkRepository.current();
    if (darwin == null) {
      throw FlutterBuildError(
        'FlutterDebugBundler: no usable toolchain. No Darwin SDK found.\n'
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>` first.',
      );
    }
    return Toolchain(
      clang: await runtime.toolchain.resolveDarwinClang(
        runtime.sdkRepository.iosSdk(darwin, target: deploymentTarget.platform),
      ),
      iosSdk: runtime.sdkRepository.iosSdk(
        darwin,
        target: deploymentTarget.platform,
      ),
      linker: await runtime.toolchain.resolveLd64Lld(),
    );
  }

  @visibleForTesting
  Future<void> buildAppStub(String appFramework, Toolchain toolchain) =>
      runtime.runner.log.logStep('Building App.framework', () async {
        final tmp = await runtime.host.fileSystem
            .directory(runtime.host.paths.temporaryRoot)
            .createTemp('xcross-flutter-stub-');
        final stubSource = p.join(tmp.path, 'debug_app.c');
        // Exact stub content emitted by flutter_tools.
        await runtime.host.fileSystem
            .file(stubSource)
            .writeAsString('static const int Moo = 88;\n');

        await runtime.host.fileSystem
            .directory(appFramework)
            .create(recursive: true);
        final outputBinary = p.join(appFramework, 'App');

        // Flags mirror flutter_tools `_createStubAppFramework`.
        final args = appStubClangArgs(
          toolchain: toolchain,
          stubSource: stubSource,
          outputBinary: outputBinary,
          deploymentTarget: deploymentTarget,
        );

        await runtime.runner.runChecked(
          toolchain.clang,
          args,
          inheritStdio: runtime.runner.log.isVerbose,
          label: 'clang',
        );

        final outputBinaryExists = runtime.host.fileSystem
            .file(outputBinary)
            .existsSync();
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
      deploymentTarget.minimumVersionFlag,
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
    runtime.host.fileSystem
        .file(p.join(appFramework, 'Info.plist'))
        .writeAsStringSync(appFrameworkInfoPlist(deploymentTarget));
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
