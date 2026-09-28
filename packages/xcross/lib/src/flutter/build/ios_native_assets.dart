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

/// Runs Flutter's native-assets targets without replacing xcross's custom
/// kernel/App.framework build.
final class IosNativeAssetsBuilder {
  IosNativeAssetsBuilder({
    required this.projectRoot,
    required this.flutterRoot,
    required this.deploymentTarget,
  });

  final String projectRoot;
  final String flutterRoot;
  final IosDeploymentTarget deploymentTarget;

  Future<IosNativeAssetsBuildResult> build() async {
    final output = p.join(projectRoot, 'build', 'xcross-native-assets');
    final outputDirectory = Directory(output);
    // Deliberately not cleared. `flutter assemble` is incremental and treats
    // this directory as its output set, so deleting it forced every target,
    // including every native build hook, to re-run on each build.
    await outputDirectory.create(recursive: true);

    if (!hasNativeAssetsBuildHooks(projectRoot)) {
      return IosNativeAssetsBuildResult(
        manifestPath: await _writeEmptyManifest(output),
        frameworks: const [],
      );
    }

    final tools = await AppleToolShimConfig.resolve(deploymentTarget.version);
    final forwarder = await resolveNativeAssetToolForwarder(
      Platform.resolvedExecutable,
    );
    if (forwarder == null) throw missingNativeAssetToolForwarderError();
    final engineCache = IosEngineCache(flutterRoot: flutterRoot);
    await engineCache.ensureArtifactsAvailable();
    final workspace = await FlutterToolWorkspace.create(
      flutterRoot: flutterRoot,
      engineCache: engineCache,
    );
    final shimsRoot = p.join(projectRoot, 'build', 'xcross-apple-tools');
    final shimsDirectory = await ensureAppleToolShims(
      shimsRoot,
      tools,
      toolForwarderExecutable: forwarder,
    );
    try {
      await _runFlutterAssemble(
        output,
        shimsDirectory,
        tools.iosSdk,
        workspace,
      );
    } finally {
      await workspace.dispose();
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

  Future<void> _runFlutterAssemble(
    String output,
    String shimDirectory,
    String iosSdk,
    FlutterToolWorkspace workspace,
  ) async {
    final targetFile = await _ensureStubEntrypoint(projectRoot);
    await ProcessRunner.runChecked(
      workspace.dart,
      buildFlutterAssembleArguments(
        flutterToolsSnapshot: workspace.flutterToolsSnapshot,
        output: output,
        iosSdk: iosSdk,
        targetFile: targetFile,
        deploymentTarget: deploymentTarget.version,
      ),
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

  Future<String> _writeEmptyManifest(String output) async {
    final manifest = p.join(output, 'NativeAssetsManifest.json');
    await File(
      manifest,
    ).writeAsString('{"format-version":[1,0,0],"native-assets":{}}');
    return manifest;
  }
}

/// Assemble only needs `KernelSnapshot`'s output for the native-assets
/// pipeline to run (it does not consume the app's own kernel/asset copy in
/// debug), so a stub entrypoint avoids duplicating xcross's own kernel
/// compile and its full-app depfile churn on every Dart source edit.
Future<String> _ensureStubEntrypoint(String projectRoot) async {
  final directory = Directory(
    p.join(projectRoot, 'build', 'xcross-native-assets-entry'),
  );
  await directory.create(recursive: true);
  final file = File(p.join(directory.path, 'main.dart'));
  const contents = 'void main() {}\n';
  if (!file.existsSync() || await file.readAsString() != contents) {
    await file.writeAsString(contents);
  }
  return file.path;
}

/// Builds the `flutter assemble` argument list for the native-assets-only
/// build so tests can assert the stub entrypoint is used.
@visibleForTesting
List<String> buildFlutterAssembleArguments({
  required String flutterToolsSnapshot,
  required String output,
  required String iosSdk,
  required String targetFile,
  required String deploymentTarget,
}) => [
  flutterToolsSnapshot,
  'assemble',
  '--no-version-check',
  '-o',
  output,
  '-dTargetPlatform=ios',
  '-dBuildMode=debug',
  '-dIosArchs=arm64',
  '-dSdkRoot=$iosSdk',
  '-dTargetFile=$targetFile',
  '-dIosDeploymentTarget=$deploymentTarget',
  'debug_ios_bundle_flutter_assets',
];
