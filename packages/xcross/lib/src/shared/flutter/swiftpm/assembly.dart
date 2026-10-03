import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmAssembly<T extends PlatformHostInterface> {
  SwiftPmAssembly({required this.hostPolicy});
  final SwiftPmHostPolicy hostPolicy;


  /// Finds and fixes every dylib emitted into SwiftPM's target debug output.
  Future<GeneratedPluginsBuildResult> discoverAndRewriteDylibs(
    String targetDebugDir,
  ) async {
    final dylibPaths = <String>[];
    await for (final entity in Directory(targetDebugDir).list()) {
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
      await hostPolicy.rewriteDylib(path, dylibNames);
    }
    // SwiftPM emits .swiftmodule files into a sibling `Modules` directory;
    // app-extension targets importing a plugin need it on their include path.
    final modules = Directory(p.join(targetDebugDir, 'Modules'));
    return GeneratedPluginsBuildResult(
      libraryPath: aggregatePath,
      dylibPaths: List.unmodifiable(dylibPaths),
      modulesDir: modules.existsSync() ? p.absolute(modules.path) : null,
    );
  }
}
