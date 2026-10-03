import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
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
final class IosNativeAssetsBuilder {
  IosNativeAssetsBuilder({
    required this.projectRoot,
    required this.flutterRoot,
    required this.deploymentTarget,
    this.entrypoint = 'lib/main.dart',
    this.dartDefines = const [],
    this.flavor,
  });

  final String projectRoot;
  final String flutterRoot;
  final IosDeploymentTarget deploymentTarget;
  final String entrypoint;
  final List<String> dartDefines;
  final String? flavor;

  Future<IosNativeAssetsBuildResult> build() async {
    final output = p.joinAll([
      projectRoot,
      'build',
      if (deploymentTarget.simulator) 'xcross-ios-simulator',
      'xcross-native-assets',
    ]);
    final outputDirectory = Directory(output);
    // Deliberately not cleared. `flutter assemble` is incremental and treats
    // this directory as its output set, so deleting it forced every target,
    // including every native build hook, to re-run on each build.
    await outputDirectory.create(recursive: true);

    if (!await hasNativeAssetsBuildHooks(projectRoot)) {
      return _buildBundleWithoutHooks(output);
    }

    final tools = await AppleToolShimConfig.resolve(
      deploymentTarget.version,
      simulator: deploymentTarget.simulator,
    );
    final forwarder = await resolveNativeAssetToolForwarder(
      Platform.resolvedExecutable,
    );
    if (forwarder == null) throw missingNativeAssetToolForwarderError();
    final engineCache = IosEngineCache(
      flutterRoot: flutterRoot,
      simulator: deploymentTarget.simulator,
    );
    await engineCache.ensureArtifactsAvailable();
    final workspace = await FlutterToolWorkspace.create(
      flutterRoot: flutterRoot,
      engineCache: engineCache,
    );
    final shims = await Directory.systemTemp.createTemp('xcross-apple-tools-');
    try {
      await installAppleToolShims(
        shims.path,
        tools,
        toolForwarderExecutable: forwarder,
      );
      await _runFlutterAssemble(output, shims.path, tools.iosSdk, workspace);
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
    if (!File(manifest).existsSync()) {
      throw FlutterBuildError(
        'Flutter native-assets build did not produce $manifest',
      );
    }

    final manifestFile = File(manifest);
    final original = await manifestFile.readAsString();
    final normalized = normalizeIosNativeAssetsManifest(original);
    if (normalized != original) await manifestFile.writeAsString(normalized);

    final sources = collectNativeAssetFrameworks(
      normalized,
      output,
      projectRoot: projectRoot,
    );
    final frameworks = await stageNativeAssetFrameworks(sources, output);
    await thinFrameworksToArm64(frameworks, lipo: tools.lipo);
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
    final engineCache = IosEngineCache(
      flutterRoot: flutterRoot,
      simulator: deploymentTarget.simulator,
    );
    await engineCache.ensureArtifactsAvailable();
    final workspace = await FlutterToolWorkspace.create(
      flutterRoot: flutterRoot,
      engineCache: engineCache,
    );
    final assets = p.join(output, 'App.framework', 'flutter_assets');
    try {
      await ProcessRunner.runChecked(
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
    if (!File(manifest).existsSync()) {
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
    await ProcessRunner.runChecked(
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
          ProcessRunner.environmentValue(
            ProcessRunner.effectiveEnvironment,
            'PATH',
          ),
        ),
      },
      inheritStdio: Log.isVerbose,
      label: 'Flutter native assets',
    );
  }

  String _prependPath(String directory, String? base) =>
      base == null || base.isEmpty
      ? directory
      : '$directory${Platform.isWindows ? ';' : ':'}$base';
}
