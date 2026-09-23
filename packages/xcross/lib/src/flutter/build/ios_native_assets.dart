import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/flutter_tool_workspace.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_hook_discovery.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_manifest.dart';
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';
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
    this.entrypoint = 'lib/main.dart',
  });

  final String projectRoot;
  final String flutterRoot;
  final IosDeploymentTarget deploymentTarget;
  final String entrypoint;

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
    final stage = Directory(p.join(output, 'xcross_staged_frameworks'));
    if (stage.existsSync()) await stage.delete(recursive: true);
    await stage.create(recursive: true);
    final frameworks = <String>[];
    for (final source in sources) {
      final destination = p.join(stage.path, p.basename(source));
      await copyDirectoryPreservingSymlinks(source, destination);
      frameworks.add(destination);
    }
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
    await ProcessRunner.runChecked(
      workspace.dart,
      [
        workspace.flutterToolsSnapshot,
        'assemble',
        '--no-version-check',
        '-o',
        output,
        '-dTargetPlatform=ios',
        '-dBuildMode=debug',
        '-dIosArchs=arm64',
        '-dSdkRoot=$iosSdk',
        '-dTargetFile=$entrypoint',
        '-dIosDeploymentTarget=${deploymentTarget.version}',
        'debug_ios_bundle_flutter_assets',
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

  Future<String> _writeEmptyManifest(String output) async {
    final manifest = p.join(output, 'NativeAssetsManifest.json');
    await File(
      manifest,
    ).writeAsString('{"format-version":[1,0,0],"native-assets":{}}');
    return manifest;
  }
}
