import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

/// Maps local file paths to `package:` URIs via a project's
/// `.dart_tool/package_config.json`, so breakpoints match reliably: the VM
/// matches breakpoints by `package:` URI, not by absolute path, which
/// differs between the compile host and the editor.
final class PackageUris {
  PackageUris._(this._config, this.paths);

  final PackageConfig _config;
  final p.Context paths;

  /// `file:///…/lib/main.dart` → `package:my_app/main.dart`.
  ///
  /// Null when [fileUri] is not a file URI or falls outside a package's `lib/`
  /// (e.g. `test/`, `bin/`, or a path outside the project).
  Uri? toPackageUri(Uri fileUri) =>
      fileUri.isScheme('file') ? _config.toPackageUri(fileUri) : null;

  /// [path] as a `package:` URI string, or [path] unchanged when it has no
  /// package equivalent. Suitable for handing straight to `frontend_server`.
  String toCompilerUri(String path) =>
      toPackageUri(paths.toUri(paths.absolute(path)))?.toString() ?? path;
}

final class PackageUriLoader {
  const PackageUriLoader({required this.fileSystem, required this.paths});

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  Future<PackageUris?> load(String packageConfigPath) async {
    try {
      final config = await loadPackageConfigUri(
        paths.toUri(paths.absolute(packageConfigPath)),
        loader: (uri) async {
          if (!uri.isScheme('file')) return null;
          final file = fileSystem.file(paths.fromUri(uri));
          return file.existsSync() ? file.readAsBytes() : null;
        },
      );
      return PackageUris._(config, paths);
    } on Object {
      return null;
    }
  }
}
