import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';

final class SwiftPmClangModules {
static List<String> topLevelModuleNames(String moduleMap) {
    final code = SwiftPmManifestLexer.swiftCodeMask(moduleMap);
    final names = <String>[];
    var depth = 0;
    var lineStart = 0;
    for (var i = 0; i <= moduleMap.length; i++) {
      if (i == moduleMap.length || moduleMap[i] == '\n') {
        if (depth == 0) {
          final line = moduleMap.substring(lineStart, i);
          final match = RegExp(
            r'^\s*(?:(?:framework|explicit)\s+)?module\s+'
            r'([A-Za-z_][A-Za-z0-9_]*)\s*\{',
          ).firstMatch(line);
          if (match != null) names.add(match[1]!);
        }
        for (var j = lineStart; j < i; j++) {
          if (!code[j]) continue;
          if (moduleMap[j] == '{') depth++;
          if (moduleMap[j] == '}') depth--;
        }
        lineStart = i + 1;
      }
    }
    return names;
  }

static ({int start, int open, int close})? moduleBlock(
    String moduleMap,
    String name,
  ) {
    final declaration = RegExp(
      r'^\s*(?:(?:framework|explicit)\s+)?module\s+'
      '${RegExp.escape(name)}\\s*\\{',
      multiLine: true,
    ).firstMatch(moduleMap);
    if (declaration == null) return null;
    final open = moduleMap.indexOf('{', declaration.start);
    final close = SwiftPmManifestLexer.indexOfMatchingDelimiter(moduleMap, open);
    return close < 0
        ? null
        : (start: declaration.start, open: open, close: close);
  }

static List<({String path, bool directory})> directModuleHeaders(
    String moduleMap,
    ({int start, int open, int close}) block,
  ) {
    final code = SwiftPmManifestLexer.swiftCodeMask(moduleMap);
    final headers = <({String path, bool directory})>[];
    var depth = 1;
    var lineStart = block.open + 1;
    for (var i = block.open + 1; i <= block.close; i++) {
      if (i != block.close && moduleMap[i] != '\n') continue;
      final line = moduleMap.substring(lineStart, i);
      if (depth == 1) {
        final header = RegExp(
          r'^\s*(?:umbrella\s+)?header\s+"([^"]+)"',
        ).firstMatch(line);
        final umbrella = RegExp(r'^\s*umbrella\s+"([^"]+)"').firstMatch(line);
        if (header != null) {
          headers.add((path: header[1]!, directory: false));
        } else if (umbrella != null) {
          headers.add((path: umbrella[1]!, directory: true));
        }
      }
      for (var j = lineStart; j < i; j++) {
        if (!code[j]) continue;
        if (moduleMap[j] == '{') depth++;
        if (moduleMap[j] == '}') depth--;
      }
      lineStart = i + 1;
    }
    return headers;
  }

static int braceDepthAt(String source, int offset) {
    final code = SwiftPmManifestLexer.swiftCodeMask(source);
    var depth = 0;
    for (var i = 0; i < offset; i++) {
      if (!code[i]) continue;
      if (source[i] == '{') depth++;
      if (source[i] == '}') depth--;
    }
    return depth;
  }

static List<String> directNestedModules(
    String moduleMap,
    ({int start, int open, int close}) parent,
  ) {
    final nested = <String>[];
    final declaration = RegExp(
      r'^\s*(?:(?:framework|explicit)\s+)?module\s+'
      r'[A-Za-z_][A-Za-z0-9_]*\s*\{',
      multiLine: true,
    );
    for (final match in declaration.allMatches(moduleMap, parent.open + 1)) {
      if (match.start >= parent.close) break;
      if (SwiftPmClangModules.braceDepthAt(moduleMap, match.start) != 1) continue;
      final open = moduleMap.indexOf('{', match.start);
      final close = SwiftPmManifestLexer.indexOfMatchingDelimiter(moduleMap, open);
      if (close < 0 || close > parent.close) continue;
      nested.add(moduleMap.substring(match.start, close + 1).trim());
    }
    return nested;
  }
}
