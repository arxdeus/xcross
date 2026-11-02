import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';

@internal
final class FlutterFrameworkCopier {
  FlutterFrameworkCopier(this.fileSystem, this.paths, {required this.copier});
  final RecursiveDirectoryCopier copier;

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
          .copy(
            fileSystem
                .file(paths.join(frameworksDir, paths.basename(library)))
                .path,
          );
    }
  }

  /// Copies every native-asset framework into the app's Frameworks directory.
  Future<void> copyNativeAssetFrameworks(
    Iterable<String> frameworks,
    String frameworksDir,
  ) async {
    for (final framework in frameworks) {
      await copier.copy(
        framework,
        paths.join(frameworksDir, paths.basename(framework)),
      );
    }
  }

  Future<List<String>> copyMissingFrameworks(
    Iterable<String> frameworks,
    String frameworksDir,
  ) async {
    final copied = <String>[];
    for (final framework in frameworks) {
      final destination = paths.join(frameworksDir, paths.basename(framework));
      if (fileSystem.directory(destination).existsSync()) continue;
      await copier.copy(framework, destination);
      copied.add(destination);
    }
    return copied;
  }

  /// Copies SwiftPM resource bundles (`<Package>_<Target>.bundle`) into the
  /// application root, where Xcode places them and where SwiftPM's generated
  /// `Bundle.module` accessor looks (`Bundle.main.bundleURL`). Must run
  /// before signing so the bundles are sealed into the app's resources.
  Future<List<String>> copyResourceBundles(
    Iterable<String> bundles,
    String bundleDir,
  ) async {
    final copied = <String>[];
    for (final bundle in bundles) {
      final destination = paths.join(bundleDir, paths.basename(bundle));
      if (fileSystem.directory(destination).existsSync()) continue;
      await copier.copy(bundle, destination);
      copied.add(destination);
    }
    return copied;
  }
}
