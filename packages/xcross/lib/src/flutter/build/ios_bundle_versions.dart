import 'package:meta/meta.dart';

/// The version pair every bundle in an app must agree on.
///
/// iOS requires an embedded app extension's `CFBundleShortVersionString` and
/// `CFBundleVersion` to match its host app's; installd rejects a mismatched
/// pair, and a stale extension version silently breaks upgrades.
@immutable
final class IosBundleVersions {
  const IosBundleVersions({
    required this.shortVersion,
    required this.bundleVersion,
  });

  /// Fallbacks matching Flutter's own defaults.
  static const fallback = IosBundleVersions(
    shortVersion: '1.0.0',
    bundleVersion: '1',
  );

  /// `CFBundleShortVersionString`, from `MARKETING_VERSION`.
  final String shortVersion;

  /// `CFBundleVersion`, from `CURRENT_PROJECT_VERSION`.
  final String bundleVersion;

  @override
  String toString() => '$shortVersion ($bundleVersion)';
}
