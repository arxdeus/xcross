import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';

final class FlutterFrameworkCopier {
  FlutterFrameworkCopier(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  /// Copies every SwiftPM-produced dylib into the app's Frameworks directory.
  Future<void> copyPluginLibraries(
    Iterable<String> pluginLibraries,
    String frameworksDir,
  ) async {
    for (final library in pluginLibraries) {
      await fileSystem
          .file(library)
          .copy(paths.join(frameworksDir, paths.basename(library)));
    }
  }

  /// Copies every native-asset framework into the app's Frameworks directory.
  Future<void> copyNativeAssetFrameworks(
    Iterable<String> frameworks,
    String frameworksDir,
  ) async {
    for (final framework in frameworks) {
      await copyDirectoryPreservingSymlinks(
        framework,
        paths.join(frameworksDir, paths.basename(framework)),
      );
    }
  }
}
