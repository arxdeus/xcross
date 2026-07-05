import 'package:meta/meta.dart';

/// Result of a pack operation: the `.app` path and its bundle identifier.
///
/// Unified from `ComposePackResult` and `FlutterPackResult` — both carry
/// identical `(String appPath, String bundleId)` fields.
@immutable
class PackResult {
  const PackResult(this.appPath, this.bundleId);

  /// Absolute path to the built `.app` bundle.
  final String appPath;

  /// iOS bundle identifier (e.g. `com.example.MyApp`).
  final String bundleId;
}
