import 'package:path/path.dart' as p;

/// Validates archive entry names before they are turned into real paths.
abstract final class ArchiveEntryPath {
  /// The destination-relative path for [name], or null when the entry must be
  /// refused.
  ///
  /// A release archive is attacker-controlled data as far as this process is
  /// concerned, so absolute paths, drive letters, UNC prefixes and any `..`
  /// segment are rejected outright rather than normalised away.
  static String? sanitize(String name) {
    final normalized = name.replaceAll(r'\', '/').trim();
    if (normalized.isEmpty) return null;
    if (normalized.startsWith('/')) return null;
    if (_driveLetter.hasMatch(normalized)) return null;

    final segments = <String>[];
    for (final segment in normalized.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (!_isSafeSegment(segment)) return null;
      segments.add(segment);
    }
    if (segments.isEmpty) return null;
    return segments.join('/');
  }

  static final _driveLetter = RegExp('^[A-Za-z]:');

  /// Win32 strips trailing dots and spaces from every path component before
  /// opening it, so `".. "` and `".."` name the same directory there. Comparing
  /// against `'..'` alone would let such a segment through on Windows, so the
  /// trailing run is removed before the check. `:` is refused outright because
  /// it opens an NTFS alternate data stream.
  static bool _isSafeSegment(String segment) {
    if (segment.contains(':')) return false;
    final trimmed = segment.replaceAll(_trailingDotsOrSpaces, '');
    return trimmed.isNotEmpty && trimmed != '..' && trimmed != '.';
  }

  static final _trailingDotsOrSpaces = RegExp(r'[. ]+$');

  /// The absolute destination for [name] under [root], or null when the entry
  /// is refused or would escape [root].
  static String? resolve(String root, String name) {
    final relative = sanitize(name);
    if (relative == null) return null;
    final base = p.normalize(p.absolute(root));
    final target = p.normalize(p.join(base, relative));
    if (target == base || !p.isWithin(base, target)) return null;
    return target;
  }
}
