import 'dart:io';

import 'package:package_config/package_config.dart';

/// Maps local file paths to `package:` URIs via a project's
/// `.dart_tool/package_config.json`, so breakpoints match reliably: the VM
/// matches breakpoints by `package:` URI, not by absolute path, which
/// differs between the compile host and the editor.
final class PackageUris {
  PackageUris._(this._config);

  final PackageConfig _config;

  /// Null when the config is missing or unparseable; callers then fall back to
  /// plain file paths, which is the pre-existing behaviour.
  static Future<PackageUris?> load(String packageConfigPath) async {
    final file = File(packageConfigPath);
    if (!file.existsSync()) return null;
    try {
      return PackageUris._(await loadPackageConfigUri(file.uri));
    } on Object {
      return null;
    }
  }

  /// `file:///…/lib/main.dart` → `package:my_app/main.dart`.
  ///
  /// Null when [fileUri] is not a file URI or falls outside a package's `lib/`
  /// (e.g. `test/`, `bin/`, or a path outside the project).
  Uri? toPackageUri(Uri fileUri) =>
      fileUri.isScheme('file') ? _config.toPackageUri(fileUri) : null;

  /// [path] as a `package:` URI string, or [path] unchanged when it has no
  /// package equivalent. Suitable for handing straight to `frontend_server`.
  String toCompilerUri(String path) =>
      toPackageUri(Uri.file(path))?.toString() ?? path;
}
