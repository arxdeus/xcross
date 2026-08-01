import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/build/flutter_packer.dart';
import 'package:xcross/src/build/ios_engine_cache.dart';
import 'package:xcross/src/models/device/hot_reload_config.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Groups hot-reload configuration setup.
abstract final class HotReloadSetup {
  /// Resolve the paths a persistent `frontend_server` needs for hot reload.
  ///
  /// Returns null (with a warning) if a required artifact is missing —
  /// callers then launch without hot reload.
  static Future<HotReloadConfig?> buildHotReloadConfig({
    required String target,
    required List<String> dartDefines,
    bool verbose = false,
  }) async {
    final projectRoot = Directory.current.path;
    final flutterRoot = await FlutterPacker.resolveFlutterRoot(
      projectRoot: projectRoot,
    );
    final engineCache = IosEngineCache(flutterRoot: flutterRoot);

    final frontendServer = engineCache.frontendServer;
    final frontendServerExists = File(frontendServer).existsSync();
    if (!frontendServerExists) {
      Log.logWarn(
        'frontend_server snapshot missing at $frontendServer; '
        'hot reload disabled.',
      );
      return null;
    }

    final sdkRoot = engineCache.patchedSdkRoot;
    final packageConfig = p.join(
      projectRoot,
      '.dart_tool',
      'package_config.json',
    );
    final entrypoint = p.isAbsolute(target)
        ? target
        : p.join(projectRoot, target);

    // frontend_server is AOT (dartaotruntime) or a kernel snapshot (dart).
    final dartSdkBin = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin');
    final isAot = p.basename(frontendServer).contains('_aot');
    final dart = p.join(
      dartSdkBin,
      ProcessRunner.hostExecutableName(isAot ? 'dartaotruntime' : 'dart'),
    );

    // Persistent dill output for incremental reloads.
    final outputDill = p.join(
      projectRoot,
      'build',
      'xcross-flutter-debug',
      '.hotreload',
      'app.dill',
    );
    await Directory(p.dirname(outputDill)).create(recursive: true);

    return HotReloadConfig(
      dart: dart,
      frontendServer: frontendServer,
      sdkRoot: sdkRoot,
      packageConfig: packageConfig,
      entrypoint: entrypoint,
      projectRoot: projectRoot,
      outputDill: outputDill,
      dartDefines: dartDefines,
      verbose: verbose,
    );
  }
}
