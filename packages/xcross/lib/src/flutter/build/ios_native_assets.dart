import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_hook_discovery.dart';
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
    if (outputDirectory.existsSync()) {
      await outputDirectory.delete(recursive: true);
    }
    await outputDirectory.create(recursive: true);

    if (!hasNativeAssetsBuildHooks(projectRoot)) {
      return IosNativeAssetsBuildResult(
        manifestPath: await _writeEmptyManifest(output),
        frameworks: const [],
      );
    }

    final tools = await AppleToolShimConfig.resolve(deploymentTarget.version);
    final engineCache = IosEngineCache(flutterRoot: flutterRoot);
    await engineCache.ensureArtifactsAvailable();
    final flutterCachedFramework = p.join(
      flutterRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'ios',
      'Flutter.xcframework',
    );
    final stagedEngine = !Directory(flutterCachedFramework).existsSync();
    if (stagedEngine) {
      await copyDirectoryPreservingSymlinks(
        engineCache.flutterXcframework,
        flutterCachedFramework,
      );
    }
    final shims = await Directory.systemTemp.createTemp('xcross-apple-tools-');
    try {
      await installAppleToolShims(
        shims.path,
        tools,
        toolForwarderExecutable: await resolveNativeAssetToolForwarder(
          Platform.resolvedExecutable,
        ),
      );
      await _runFlutterAssemble(output, shims.path, tools.iosSdk);
    } finally {
      await shims.delete(recursive: true);
      if (stagedEngine) {
        await Directory(flutterCachedFramework).delete(recursive: true);
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

    final frameworks = collectNativeAssetFrameworks(output);
    await thinFrameworksToArm64(frameworks, lipo: tools.lipo);
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
  ) async {
    final flutter = p.join(
      flutterRoot,
      'bin',
      ProcessRunner.hostExecutableName('flutter', windowsExtension: '.bat'),
    );
    await ProcessRunner.runChecked(
      flutter,
      [
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
        'PATH':
            '$shimDirectory${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
      },
      inheritStdio: Log.isVerbose,
      label: 'Flutter native assets',
    );
  }

  Future<String> _writeEmptyManifest(String output) async {
    final manifest = p.join(output, 'NativeAssetsManifest.json');
    await File(
      manifest,
    ).writeAsString('{"format-version":[1,0,0],"native-assets":{}}');
    return manifest;
  }
}
