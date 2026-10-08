import 'package:meta/meta.dart';

@internal
final class SwiftPmManifestLexer {
  static List<bool> swiftCodeMask(String source) {
    final code = List<bool>.filled(source.length, true);
    var i = 0;
    while (i < source.length) {
      if (source.startsWith('//', i)) {
        final end = source.indexOf('\n', i + 2);
        final limit = end < 0 ? source.length : end;
        for (; i < limit; i++) {
          code[i] = false;
        }
        continue;
      }
      if (source.startsWith('/*', i)) {
        var depth = 0;
        do {
          if (source.startsWith('/*', i)) {
            depth++;
            code[i++] = false;
            if (i < source.length) code[i++] = false;
          } else if (source.startsWith('*/', i)) {
            depth--;
            code[i++] = false;
            if (i < source.length) code[i++] = false;
          } else {
            code[i++] = false;
          }
        } while (i < source.length && depth > 0);
        continue;
      }

      var hashes = 0;
      while (i + hashes < source.length && source[i + hashes] == '#') {
        hashes++;
      }
      final quote = i + hashes;
      if (quote < source.length &&
          source[quote] == '"' &&
          (hashes == 0 || quote > i)) {
        final quotes = source.startsWith('"""', quote) ? 3 : 1;
        final delimiter =
            '${quotes == 3 ? '"""' : '"'}${List.filled(hashes, '#').join()}';
        var cursor = quote + quotes;
        while (cursor < source.length) {
          if (source.startsWith(delimiter, cursor)) {
            cursor += delimiter.length;
            break;
          }
          if (hashes == 0 && source[cursor] == r'\') {
            cursor += 2;
          } else {
            cursor++;
          }
        }
        final end = cursor.clamp(0, source.length);
        for (var j = i; j < end; j++) {
          code[j] = false;
        }
        i = end;
        continue;
      }
      i++;
    }
    return code;
  }

  /// `let name = "..."` string constants, so `.package(url: name, ...)`
  /// (firebase-ios-sdk's `appMeasurementURL`) can be vendored like literals.
  static Map<String, String> manifestStringConstants(String manifest) {
    final pattern = RegExp(
      r'\b(?:let|var)\s+(?<name>[A-Za-z_]\w*)\s*(?::\s*[\w.<>]+)?\s*=\s*"(?<value>[^"\r\n]*)"',
    );
    return {
      for (final match in pattern.allMatches(manifest))
        match.namedGroup('name')!: match.namedGroup('value')!,
    };
  }

  /// Index of the `)` that closes the `(` at [openIndex], or -1.
  static int indexOfMatchingParen(String source, int openIndex) {
    var depth = 0;
    var inString = false;
    for (var i = openIndex; i < source.length; i++) {
      final c = source[i];
      if (inString) {
        if (c == r'\' && i + 1 < source.length) {
          i++;
          continue;
        }
        if (c == '"') inString = false;
        continue;
      }
      if (c == '"') {
        inString = true;
        continue;
      }
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static List<({int start, int end, String text})> swiftCalls(
    String source,
    String name,
  ) {
    final calls = <({int start, int end, String text})>[];
    final pattern = RegExp('${RegExp.escape(name)}\\s*\\(');
    for (final match in pattern.allMatches(source)) {
      final close = SwiftPmManifestLexer.indexOfMatchingParen(
        source,
        match.end - 1,
      );
      if (close >= 0) {
        calls.add((
          start: match.start,
          end: close + 1,
          text: source.substring(match.start, close + 1),
        ));
      }
    }
    return calls;
  }

  static List<String> iosPlatformVersions(String manifest) {
    final code = SwiftPmManifestLexer.swiftCodeMask(manifest);
    final versions = <String>[];
    for (final call in SwiftPmManifestLexer.swiftCalls(manifest, '.iOS')) {
      if (!code[call.start]) continue;
      final argument = call.text.substring(call.text.indexOf('(') + 1).trim();
      final literal = RegExp(r'^"(\d+(?:\.\d+)*)"').firstMatch(argument);
      final member = RegExp(
        r'^\.v(\d+)(?:_(\d+))?(?:_(\d+))?\b',
      ).firstMatch(argument);
      if (literal != null) {
        versions.add(literal[1]!);
      } else if (member != null) {
        versions.add(
          [
            member[1]!,
            member[2] ?? '0',
            if (member[3] case final String patch) patch,
          ].join('.'),
        );
      }
    }
    return versions;
  }

  static String? namedString(String call, String name) =>
      RegExp('${RegExp.escape(name)}\\s*:\\s*"([^"]+)"').firstMatch(call)?[1];

  static List<String> namedStringList(String call, String name) {
    final argument = RegExp('${RegExp.escape(name)}\\s*:').firstMatch(call);
    if (argument == null) return const [];
    final open = call.indexOf('[', argument.end);
    if (open < 0) return const [];
    final close = SwiftPmManifestLexer.indexOfMatchingDelimiter(call, open);
    if (close < 0) return const [];
    return [
      for (final match in RegExp(
        '"([^"]+)"',
      ).allMatches(call.substring(open + 1, close)))
        match[1]!,
    ];
  }

  static int indexOfMatchingDelimiter(String source, int openIndex) {
    final open = source[openIndex];
    final close = switch (open) {
      '(' => ')',
      '[' => ']',
      '{' => '}',
      _ => '',
    };
    if (close.isEmpty) return -1;
    final code = SwiftPmManifestLexer.swiftCodeMask(source);
    var depth = 0;
    for (var i = openIndex; i < source.length; i++) {
      if (!code[i]) continue;
      if (source[i] == open) {
        depth++;
      } else if (source[i] == close && --depth == 0) {
        return i;
      }
    }
    return -1;
  }

  static ({int open, int close})? fallbackBlock(String manifest) {
    final marker = manifest.indexOf('products.removeAll()');
    if (marker < 0) return null;
    final open = manifest.lastIndexOf('{', marker);
    if (open < 0) return null;
    final close = SwiftPmManifestLexer.indexOfMatchingDelimiter(manifest, open);
    return close < 0 ? null : (open: open, close: close);
  }
}
