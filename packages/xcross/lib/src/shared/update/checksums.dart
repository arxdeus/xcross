import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:xcross/src/shared/errors/errors.dart';

/// Reads and applies the `SHA256SUMS.txt` published with every release.
abstract final class Checksums {
  /// Parses `sha256sum` output into a filename-to-digest map.
  ///
  /// `sha256sum` separates the digest from the name with two spaces (`  ` for
  /// text mode, ` *` for binary); both are accepted. Blank lines are skipped
  /// and anything else is rejected rather than silently dropped, so a
  /// truncated or HTML error page can never parse as an empty-but-valid file.
  static Map<String, String> parse(String contents) {
    final digests = <String, String>{};
    for (final raw in const LineSplitter().convert(contents)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final match = _line.firstMatch(line);
      if (match == null) {
        throw XcrossError('malformed SHA256SUMS.txt line: $raw');
      }
      final name = match[2]!;
      // Taking the last of two entries for one name would let a manifest carry
      // both the real digest and one chosen to match a substituted archive.
      if (digests.containsKey(name)) {
        throw XcrossError('SHA256SUMS.txt lists $name more than once');
      }
      digests[name] = match[1]!.toLowerCase();
    }
    return digests;
  }

  static final _line = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(\S+)$');

  /// Lowercase SHA-256 of [bytes].
  static String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

  /// Throws unless [bytes] matches the [name] entry in [contents].
  ///
  /// Fail-closed: a missing entry is as fatal as a mismatch.
  static void verify({
    required String name,
    required List<int> bytes,
    required String contents,
  }) {
    final expected = parse(contents)[name];
    if (expected == null) {
      throw XcrossError(
        'SHA256SUMS.txt has no entry for $name; refusing to install',
      );
    }
    final actual = digestOf(bytes);
    if (actual != expected) {
      throw XcrossError(
        'checksum mismatch for $name\n'
        '  expected: $expected\n'
        '  actual:   $actual',
      );
    }
  }
}
