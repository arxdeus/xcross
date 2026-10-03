abstract final class PlistMutations {
  static String setBundleIdentifier(String plistXml, String bundleId) =>
      _setPlistKey(plistXml, 'CFBundleIdentifier', bundleId);

  static String setPlistString(String plistXml, String key, String value) =>
      _setPlistKey(plistXml, key, value);

  static String? readBundleIdentifier(String plistXml) {
    final match = RegExp(
      r'<key>CFBundleIdentifier</key>\s*<string>([^<]*)</string>',
    ).firstMatch(plistXml);
    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  static String rewriteUrlSchemes(
    String plistXml, {
    required String from,
    required String to,
  }) {
    if (from == to || from.isEmpty) return plistXml;

    final arrays = RegExp(
      r'(<key>\s*CFBundleURLSchemes\s*</key>\s*<array>)(.*?)(</array>)',
      dotAll: true,
    );
    return plistXml.replaceAllMapped(arrays, (match) {
      final body = match
          .group(2)!
          .replaceAllMapped(
            RegExp('<string>([^<]*)</string>'),
            (scheme) =>
                '<string>${scheme.group(1)!.replaceAll(from, to)}</string>',
          );
      return '${match.group(1)}$body${match.group(3)}';
    });
  }

  static String _setPlistKey(String xml, String key, String value) {
    final pattern = RegExp(
      '<key>$key</key>\\s*<string>[^<]*</string>',
      dotAll: true,
    );
    final replacement = '<key>$key</key>\n\t<string>$value</string>';
    if (xml.contains('<key>$key</key>')) {
      return xml.replaceAll(pattern, replacement);
    }
    return insertBeforeEnd(xml, '\t$replacement\n');
  }

  static String removePlistKey(String plistXml, String key) {
    final keyTag = '<key>$key</key>';
    var xml = plistXml;
    while (true) {
      final keyStart = xml.indexOf(keyTag);
      if (keyStart < 0) return xml;
      final valueEnd = _endOfValueAfter(xml, keyStart + keyTag.length);
      if (valueEnd < 0) return xml;
      var cut = keyStart;
      while (cut > 0 && (xml[cut - 1] == '\t' || xml[cut - 1] == ' ')) {
        cut--;
      }
      if (cut > 0 && xml[cut - 1] == '\n') cut--;
      xml = xml.substring(0, cut) + xml.substring(valueEnd);
    }
  }

  static int _endOfValueAfter(String xml, int from) {
    final open = RegExp(r'<(\w+)(\s[^>]*)?(/)?>');
    final match = open.firstMatch(xml.substring(from));
    if (match == null) return -1;
    final tag = match.group(1)!;
    final absoluteStart = from + match.start;
    if (match.group(3) != null) return absoluteStart + match.group(0)!.length;

    final nested = RegExp('<$tag(?:\\s[^>]*)?>|</$tag>');
    var depth = 0;
    for (final token in nested.allMatches(xml, absoluteStart)) {
      depth += token.group(0)!.startsWith('</') ? -1 : 1;
      if (depth == 0) return token.end;
    }
    return -1;
  }

  static String insertBeforeEnd(String xml, String fragment) {
    const sentinel = '</dict>\n</plist>';
    final idx = xml.lastIndexOf(sentinel);
    if (idx >= 0) {
      return xml.substring(0, idx) + fragment + xml.substring(idx);
    }
    const dictEnd = '</dict>';
    final dictIdx = xml.lastIndexOf(dictEnd);
    if (dictIdx >= 0) {
      return xml.substring(0, dictIdx) + fragment + xml.substring(dictIdx);
    }
    return xml + fragment;
  }
}
