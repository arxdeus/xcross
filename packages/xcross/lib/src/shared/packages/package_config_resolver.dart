import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';

/// Discovers the Dart package configuration used by a Flutter project.
@internal
final class PackageConfigResolver {
  const PackageConfigResolver({required this.fileSystem, required this.paths});
  final p.Context paths;
  final HostFileSystemInterface fileSystem;

  /// Finds the nearest package configuration at [projectRoot] or an ancestor.
  Future<String?> find(String projectRoot) async {
    final directory = fileSystem.directory(projectRoot);
    if (!directory.existsSync()) return null;
    final directoryUri = paths.toUri(paths.absolute(projectRoot));
    final searchUri = directoryUri.path.endsWith('/')
        ? directoryUri
        : directoryUri.replace(path: '${directoryUri.path}/');
    final result = await findPackageConfigAndUri(
      searchUri,
      loader: (uri) async {
        final file = fileSystem.file(paths.fromUri(uri));
        if (!file.existsSync()) return null;
        final bytes = await file.readAsBytes();
        return bytes;
      },
    );
    return result == null ? null : paths.fromUri(result.file);
  }

  /// Finds the package configuration or reports how to create it.
  Future<String> require(String projectRoot) async {
    final packageConfig = await find(projectRoot);
    if (packageConfig != null) return packageConfig;
    throw FlutterBuildError(
      'package_config.json not found from $projectRoot; '
      'run `flutter pub get` or `dart pub get` first.',
    );
  }
}
