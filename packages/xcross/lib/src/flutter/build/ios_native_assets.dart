import 'dart:convert';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/flutter_tool_workspace.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_hook_discovery.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_manifest.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/dart_defines.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart';

/// Native code assets produced by Flutter's Dart build-hook pipeline.
@immutable
final class IosNativeAssetsBuildResult {
  const IosNativeAssetsBuildResult({
    required this.manifestPath,
    required this.frameworks,
  });

  final String manifestPath;
  final List<String> frameworks;
}

/// Runs Flutter's iOS asset assembly to collect native assets and notices
/// without replacing xcross's custom kernel/App.framework build.
final class IosNativeAssetsBuilder<T extends PlatformHostInterface> {
  IosNativeAssetsBuilder({
    required this.engineCache,
    required this.renderer,
    required this.runner,
    required this.tools,
    required this.projectRoot,
    required this.flutterRoot,
    required this.deploymentTarget,
    this.entrypoint = 'lib/main.dart',
    this.dartDefines = const [],
    this.flavor,
  });

  final IosEngineCache<T> engineCache;
  final AppleToolShimRenderer<T> renderer;
  IosTarget<T> get target => engineCache.target;
  T get host => target.host;
  final ProcessRunner<T> runner;
  final AppleToolShimResolver<T> tools;
  final String projectRoot;
  final String flutterRoot;
  final IosDeploymentTarget deploymentTarget;
  final String entrypoint;
  final List<String> dartDefines;
  final String? flavor;

  Future<IosNativeAssetsBuildResult> build() async {
    final output = engineCache.targetPolicy.buildDirectory(
      projectRoot,
      'xcross-native-assets',
    );
    final outputDirectory = host.fileSystem.directory(output);
    // Deliberately not cleared. `flutter assemble` is incremental and treats
    // this directory as its output set, so deleting it forced every target,
    // including every native build hook, to re-run on each build.
    await outputDirectory.create(recursive: true);

    if (!await hasNativeAssetsBuildHooks(projectRoot)) {
      return _buildBundleWithoutHooks(output);
    }

    final config = await tools.resolve(deploymentTarget.version);
    final forwarder = await tools.resolveNativeAssetToolForwarder(
      tools.executable,
    );
    if (forwarder == null) throw missingNativeAssetToolForwarderError();
    await engineCache.ensureArtifactsAvailable();
    final workspace = await FlutterToolWorkspace.create(
      flutterRoot: flutterRoot,
      engineCache: engineCache,
    );
    final shims = await host.fileSystem
        .directory(host.paths.temporaryRoot)
        .createTemp('xcross-apple-tools-');
    try {
      await installAppleToolShims(
        shims.path,
        config,
        renderer: renderer,
        toolForwarderExecutable: forwarder,
      );
      await _runFlutterAssemble(output, shims.path, config.iosSdk, workspace);
    } finally {
      try {
        await shims.delete(recursive: true);
      } finally {
        await workspace.dispose();
      }
    }

    final manifest = p.join(
      output,
      'App.framework',
      'flutter_assets',
      'NativeAssetsManifest.json',
    );
    if (!host.fileSystem.file(manifest).existsSync()) {
      throw FlutterBuildError(
        'Flutter native-assets build did not produce $manifest',
      );
    }

    final manifestFile = host.fileSystem.file(manifest);
    final original = await manifestFile.readAsString();
    final normalized = normalizeIosNativeAssetsManifest(original);
    if (normalized != original) await manifestFile.writeAsString(normalized);

    final sources = collectNativeAssetFrameworks(
      normalized,
      output,
      projectRoot: projectRoot,
    );
    final frameworks = await stageNativeAssetFrameworks(sources, output);
    await thinFrameworksToArm64(frameworks, lipo: config.lipo, runner: runner);
    await alignNativeAssetLinkedit(frameworks);
    await normalizeNativeAssetInstallNames(frameworks);

    return IosNativeAssetsBuildResult(
      manifestPath: manifest,
      frameworks: frameworks,
    );
  }

  Future<IosNativeAssetsBuildResult> _buildBundleWithoutHooks(
    String output,
  ) async {
    await engineCache.ensureArtifactsAvailable();
    final workspace = await FlutterToolWorkspace.create(
      flutterRoot: flutterRoot,
      engineCache: engineCache,
    );
    final assets = p.join(output, 'App.framework', 'flutter_assets');
    try {
      await runner.runChecked(
        workspace.dart,
        [workspace.flutterToolsSnapshot, ...assembleArguments(output: assets)],
        workingDirectory: projectRoot,
        environment: {'FLUTTER_ROOT': workspace.flutterRoot},
        inheritStdio: Log.isVerbose,
        label: 'Flutter asset bundle',
      );
    } finally {
      await workspace.dispose();
    }

    final manifest = p.join(assets, 'NativeAssetsManifest.json');
    if (!host.fileSystem.file(manifest).existsSync()) {
      throw FlutterBuildError('Flutter asset bundle did not produce $manifest');
    }
    return IosNativeAssetsBuildResult(
      manifestPath: manifest,
      frameworks: const [],
    );
  }

  /// Flutter assemble inputs shared by the bundle and native-hook targets.
  /// Using assemble also preserves explicit FLUTTER_APP_FLAVOR overrides,
  /// which the higher-level `build bundle` command rejects.
  @visibleForTesting
  List<String> assembleArguments({required String output, String? iosSdk}) => [
    'assemble',
    '--no-version-check',
    '-o',
    output,
    '-dTargetPlatform=ios',
    '-dBuildMode=debug',
    '-dIosArchs=arm64',
    if (iosSdk != null) '-dSdkRoot=$iosSdk',
    '-dTargetFile=$entrypoint',
    '-dIosDeploymentTarget=${deploymentTarget.version}',
    '-dDartDefines=${DartDefines.withFlavor(dartDefines, flavor).map((define) => base64.encode(utf8.encode(define))).join(',')}',
    if (iosSdk != null)
      'debug_ios_bundle_flutter_assets'
    else
      'copy_flutter_bundle',
  ];

  Future<void> _runFlutterAssemble(
    String output,
    String shimDirectory,
    String iosSdk,
    FlutterToolWorkspace workspace,
  ) async {
    await runner.runChecked(
      workspace.dart,
      [
        workspace.flutterToolsSnapshot,
        ...assembleArguments(output: output, iosSdk: iosSdk),
      ],
      workingDirectory: projectRoot,
      // Flutter's hook runner sanitizes its environment. Tool shims therefore
      // embed resolved paths rather than reading xcross-specific variables.
      environment: {
        'FLUTTER_ROOT': workspace.flutterRoot,
        'PATH': _prependPath(
          shimDirectory,
          runner.environmentValue(runner.effectiveEnvironment, 'PATH'),
        ),
      },
      inheritStdio: Log.isVerbose,
      label: 'Flutter native assets',
    );
  }

  String _prependPath(String directory, String? base) =>
      host.environment.joinPathList([
        directory,
        if (base != null && base.isNotEmpty)
          ...host.environment.splitPathList(base),
      ]);
}
