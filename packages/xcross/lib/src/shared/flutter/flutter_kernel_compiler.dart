import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:frontend_server_kit/shared/compiler/package_uris.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/shared/flutter/build/internal/kernel_compiler.dart';
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';

@internal
final class FlutterKernelCompiler<T extends PlatformHostInterface> {
  FlutterKernelCompiler({
    required this.runtime,
    required this.registrant,
    required this.projectRoot,
    required this.flutterRoot,
    this.entrypoint = 'lib/main.dart',
    this.dartDefines = const [],
    this.buildMode = FlutterBuildMode.debug,
  }) : packageUriLoader = PackageUriLoader(
         fileSystem: runtime.host.fileSystem,
         paths: runtime.host.paths.context,
       );
  final PackageUriLoader packageUriLoader;
  final FlutterBuildRuntime<T> runtime;
  final DartPluginRegistrant registrant;
  final String projectRoot;
  final String flutterRoot;
  final String entrypoint;

  /// The build's complete dart-defines (`FlutterBuildContext.dartDefines`),
  /// forwarded as `-D<KEY=VALUE>`.
  final List<String> dartDefines;

  /// Debug compiles a hot-reloadable kernel; profile and release compile a
  /// whole-program AOT kernel for `gen_snapshot`.
  final FlutterBuildMode buildMode;
  Future<String> compile(IosEngineCache<T> engineCache) async {
    final compiler = _resolveKernelCompiler(engineCache);
    _validateKernelDependencies(compiler, engineCache);

    final outputDill = await _prepareKernelScratch();
    final packageConfig = await runtime.packageConfigs.require(projectRoot);

    final entrypointArg = await resolveEntrypointArg(packageConfig);

    // Federated plugins install their Dart-side implementation from here.
    // Without it the app boots but the first plugin call throws
    // "a platform implementation has not been set", usually before runApp,
    // which reaches the device as a black screen.
    final paths = runtime.host.paths.context;
    final registrationPath = await registrant.generate(
      projectRoot: projectRoot,
      packageConfigPath: packageConfig,
      entrypoint: paths.isAbsolute(entrypoint)
          ? entrypoint
          : paths.join(projectRoot, entrypoint),
      flutterRoot: flutterRoot,
    );
    final packageUris = await packageUriLoader.load(packageConfig);
    final registrantUri = registrationPath == null
        ? null
        : dartPluginRegistrantUri(
            registrationPath,
            packageUris,
            paths: runtime.host.paths.context,
          );
    if (registrantUri != null) {
      runtime.runner.log.logTrace('dart plugin registrant: $registrantUri');
    }

    final args = frontendServerArguments(
      compiler: compiler,
      engineCache: engineCache,
      packageConfig: packageConfig,
      outputDill: outputDill,
      entrypointArg: entrypointArg,
      dartPluginRegistrantUri: registrantUri,
    );

    await runtime.runner.log.logStep(
      'Compiling Dart kernel',
      () => runtime.runner.runChecked(
        compiler.runtime,
        args,
        workingDirectory: projectRoot,
        // Inheriting fd1 while a spinner animates shreds the line; capture
        // instead (the stderr is folded into the thrown error either way).
        inheritStdio: runtime.runner.log.isVerbose,
        label: 'frontend_server',
      ),
    );

    if (!runtime.host.fileSystem.file(outputDill).existsSync()) {
      throw FlutterBuildError(
        'FlutterDebugBundler: kernel snapshot did not produce $outputDill',
      );
    }
    return outputDill;
  }

  /// The frontend_server snapshot plus the Dart runtime that can execute it.
  /// AOT snapshots run via `dartaotruntime`; non-AOT via `dart`.
  KernelCompiler _resolveKernelCompiler(IosEngineCache<T> engineCache) {
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
        runtime.runner.hostExecutableName(runtimeName),
      ),
    );
  }

  /// Guard that all prerequisites for the kernel snapshot step exist.
  void _validateKernelDependencies(
    KernelCompiler compiler,
    IosEngineCache<T> engineCache,
  ) {
    if (!runtime.host.fileSystem.file(compiler.snapshot).existsSync()) {
      throw FlutterBuildError(
        'FlutterDebugBundler: frontend_server snapshot missing at '
        '${compiler.snapshot}.\n'
        'Run `<FLUTTER_ROOT>/bin/dart --version` once to materialize.',
      );
    }
    if (!runtime.host.fileSystem.file(compiler.runtime).existsSync()) {
      throw FlutterBuildError(
        'FlutterDebugBundler: ${compiler.runtimeName} not at '
        '${compiler.runtime}',
      );
    }
    final platformDill = p.join(
      engineCache.patchedSdkRoot,
      'platform_strong.dill',
    );
    if (!runtime.host.fileSystem.file(platformDill).existsSync()) {
      throw FlutterBuildError(
        'FlutterDebugBundler: ${engineCache.patchedSdkRoot} is missing\n'
        'platform_strong.dill. Try deleting '
        '`bin/cache/artifacts/engine/common/` and rerunning.',
      );
    }
  }

  /// Recreate the kernel scratch directory and return its `app.dill` path.
  Future<String> _prepareKernelScratch() async {
    final scratch = runtime.host.fileSystem.directory(
      p.join(
        runtime.policy.buildDirectory(
          projectRoot,
          buildMode.intermediatesDirectory,
        ),
        '.kernel',
      ),
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
  @visibleForTesting
  Future<String> resolveEntrypointArg(String packageConfig) async {
    final paths = runtime.host.paths.context;
    final resolved = paths.isAbsolute(entrypoint)
        ? entrypoint
        : paths.join(projectRoot, entrypoint);
    final packageUris = await packageUriLoader.load(packageConfig);
    return packageUris?.toCompilerUri(resolved) ?? resolved;
  }

  /// ORDER MATTERS: dartaotruntime takes `<snapshot>` as its first arg, so
  /// `dart`'s --disable-dart-dev must precede it. --sdk-root needs its
  /// trailing slash: frontend_server resolves platform_strong.dill by string
  /// concatenation. The defines and mode options follow flutter_tools'
  /// `KernelCompiler.compile` order, so a release build's `dart.vm.*` values
  /// come after, and override, the user's.
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
  static String dartPluginRegistrantUri(
    String path,
    PackageUris? packageUris, {
    required p.Context paths,
  }) {
    final fileUri = paths.toUri(paths.absolute(path));
    return packageUris?.toPackageUri(fileUri)?.toString() ?? fileUri.toString();
  }

  List<String> frontendServerArguments({
    required KernelCompiler compiler,
    required IosEngineCache<T> engineCache,
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
    if (!buildMode.isPrecompiled)
      '-Ddart.developer.serviceExtensionStream.enabled=true',
    for (final define in dartDefines) '-D$define',
    ...buildMode.frontendServerOptions(dartDefines),
    if (buildMode.isPrecompiled) ...[
      '--aot',
      '--tfa',
      '--target-os',
      'ios',
    ] else
      '--track-widget-creation',
    '--packages', packageConfig,
    '--output-dill', outputDill,
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
}
