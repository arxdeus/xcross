import 'package:meta/meta.dart';

/// A release version, parsed from a git tag or from the stamped build version.
@immutable
final class XcrossSemver implements Comparable<XcrossSemver> {
  const XcrossSemver({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease,
  });

  /// Parses `1.2.3`, `v1.2.3` or `1.2.3-dev`, returning null when [value] is
  /// not a release version.
  ///
  /// Build metadata (`+sha`) is accepted and ignored, as semver requires.
  static XcrossSemver? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    return XcrossSemver(
      major: int.parse(match[1]!),
      minor: int.parse(match[2]!),
      patch: int.parse(match[3]!),
      preRelease: match[4],
    );
  }

  static final _pattern = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  final int major;
  final int minor;
  final int patch;

  /// The `-dev` in `1.0.0-dev`, or null for a plain release.
  final String? preRelease;

  /// True when this version carries a pre-release suffix.
  bool get isPreRelease => preRelease != null;

  /// True when this version sorts strictly above [other].
  bool isNewerThan(XcrossSemver other) => compareTo(other) > 0;

  @override
  int compareTo(XcrossSemver other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return _comparePreRelease(preRelease, other.preRelease);
  }

  /// A pre-release sorts below the release it leads up to, so `1.3.0-dev` is
  /// older than `1.3.0`. Two pre-releases fall back to identifier order.
  static int _comparePreRelease(String? a, String? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  @override
  bool operator ==(Object other) =>
      other is XcrossSemver &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.preRelease == preRelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() =>
      '$major.$minor.$patch${preRelease == null ? '' : '-$preRelease'}';
}
