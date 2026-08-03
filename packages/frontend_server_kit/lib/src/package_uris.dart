import 'dart:io';

import 'package:package_config/package_config.dart';

/// Maps local file paths to `package:` URIs via a project's
/// `.dart_tool/package_config.json`.
///
/// Exists for breakpoints. The VM matches a breakpoint's script URI two ways
/// (`runtime/vm/debugger.cc`, `BreakpointLocationAtLineCol`):
///
///   * `package:` → the kernel's `Library.importUri`, host-independent.
///   * anything else → `resolved_url`, the absolute path of whichever machine
///     compiled the kernel.
///
/// On no match the VM still reports success and records a *latent* breakpoint,
/// so the editor shows it accepted but never verified — grey forever, with no
/// error anywhere. Absolute paths are exactly what differs between the compile
/// host and the editor (WSL mounts, symlinked roots, containers), so tooling
/// compiles and debugs through `package:` URIs. flutter_tools does the same.
class PackageUris {
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
