/// Build identity of this xcross binary.
abstract final class XcrossVersion {
  /// Release version, stamped from the git tag at build time by
  /// `tool/stamp_version.dart`.
  ///
  /// A checkout that was never stamped keeps the `-dev` suffix.
  static const String current = '1.0.5-dev';

  /// True when this binary was not built from a tagged release.
  static bool get isDev => current.contains('-dev');

  /// One-line `xcross --version` output.
  static String describe() =>
      isDev ? 'xcross $current (unreleased build)' : 'xcross $current';
}
