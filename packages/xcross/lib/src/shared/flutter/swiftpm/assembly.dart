import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmAssembly<T extends PlatformHostInterface> {
  SwiftPmAssembly({required this.hostBuildServices, required this.fileSystem});

  final SwiftPmHostBuildServices<T> hostBuildServices;
  final SwiftPmArtifactFileSystem fileSystem;

  /// Finds and fixes every dylib emitted into SwiftPM's target debug output.
  Future<GeneratedPluginsBuildResult> discoverAndRewriteDylibs(
    String targetDebugDir,
  ) async {
    final dylibPaths = <String>[];
    await for (final entity in fileSystem.directory(targetDebugDir).list()) {
      if (entity is File && p.extension(entity.path) == '.dylib') {
        dylibPaths.add(p.absolute(entity.path));
      }
    }
    dylibPaths.sort();

    const aggregateName = 'lib$pluginsProductName.dylib';
    final aggregatePath = dylibPaths
        .where((path) => p.basename(path) == aggregateName)
        .firstOrNull;
    if (aggregatePath == null) {
      throw FlutterBuildError(
        'GeneratedPluginsPackage: swift build did not produce the plugins '
        'library in $targetDebugDir',
      );
    }

    final dylibNames = dylibPaths.map(p.basename).toSet();
    for (final path in dylibPaths) {
      await hostBuildServices.rewriteDylib(path, dylibNames);
    }
    // SwiftPM emits .swiftmodule files into a sibling `Modules` directory;
    // app-extension targets importing a plugin need it on their include path.
    final modules = fileSystem.directory(p.join(targetDebugDir, 'Modules'));
    return GeneratedPluginsBuildResult(
      libraryPath: aggregatePath,
      dylibPaths: List.unmodifiable(dylibPaths),
      modulesDir: modules.existsSync() ? p.absolute(modules.path) : null,
    );
  }
}
