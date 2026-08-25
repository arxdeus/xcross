/// Removes host-only guards from Swift package graph builder functions.
///
/// Only function bodies returning SwiftPM graph arrays are considered. The
/// contents of matching macOS conditionals are retained, including nested
/// conditional-compilation directives.
String exposeMacOSPackageGraphEntries(String manifest) {
  final code = _swiftCodeMask(manifest);
  final removals = <(int, int)>[];
  final functionPattern = RegExp(r'\bfunc\b');
  final returnPattern = RegExp(
    r'->\s*\[\s*(?:Product|Package\s*\.\s*Dependency|Target)\s*\]'
    r'(?:\s+where\b[\s\S]*)?\s*$',
  );

  for (final function in functionPattern.allMatches(code)) {
    final bodyStart = _findFunctionBody(code, function.end);
    if (bodyStart == null ||
        !returnPattern.hasMatch(code.substring(function.end, bodyStart))) {
      continue;
    }
    final bodyEnd = _matchingBrace(code, bodyStart);
    if (bodyEnd == null) continue;
    removals.addAll(
      _macOSDirectiveRemovals(manifest, code, bodyStart + 1, bodyEnd),
    );
  }

  if (removals.isEmpty) return manifest;
  final uniqueRemovals = removals.toSet().toList()..sort((a, b) => a.$1 - b.$1);
  final result = StringBuffer();
  var position = 0;
  for (final (start, end) in uniqueRemovals) {
    result.write(manifest.substring(position, start));
    position = end;
  }
  result.write(manifest.substring(position));
  return result.toString();
}

int? _findFunctionBody(String code, int start) {
  var parentheses = 0;
  var brackets = 0;
  for (var index = start; index < code.length; index++) {
    final character = code.codeUnitAt(index);
    if (character == 0x28) parentheses++;
    if (character == 0x29 && parentheses > 0) parentheses--;
    if (character == 0x5b) brackets++;
    if (character == 0x5d && brackets > 0) brackets--;
    if (character == 0x7b && parentheses == 0 && brackets == 0) {
      return index;
    }
    if (character == 0x3b && parentheses == 0 && brackets == 0) return null;
  }
  return null;
}

int? _matchingBrace(String code, int openingBrace) {
  var depth = 1;
  for (var index = openingBrace + 1; index < code.length; index++) {
    final character = code.codeUnitAt(index);
    if (character == 0x7b) depth++;
    if (character == 0x7d && --depth == 0) return index;
  }
  return null;
}

List<(int, int)> _macOSDirectiveRemovals(
  String source,
  String code,
  int bodyStart,
  int bodyEnd,
) {
  final lines = <(int, int, String, String)>[];
  var start = bodyStart;
  while (start < bodyEnd) {
    var contentEnd = code.indexOf('\n', start);
    if (contentEnd < 0 || contentEnd > bodyEnd) contentEnd = bodyEnd;
    var trimmedEnd = contentEnd;
    if (trimmedEnd > start && code.codeUnitAt(trimmedEnd - 1) == 0x0d) {
      trimmedEnd--;
    }
    final end = contentEnd < bodyEnd ? contentEnd + 1 : contentEnd;
    lines.add((
      start,
      end,
      source.substring(start, trimmedEnd).trim(),
      code.substring(start, trimmedEnd).trim(),
    ));
    start = end;
  }

  final removals = <(int, int)>[];
  for (var index = 0; index < lines.length; index++) {
    if (lines[index].$3 != '#if os(macOS)' ||
        lines[index].$4 != '#if os(macOS)') {
      continue;
    }
    var depth = 1;
    var hasAlternative = false;
    for (var nested = index + 1; nested < lines.length; nested++) {
      final sourceDirective = lines[nested].$3;
      final codeDirective = lines[nested].$4;
      if (RegExp(r'^#if(?:\s|$)').hasMatch(codeDirective)) depth++;
      if (depth == 1 &&
          RegExp(r'^#(?:else|elseif)(?:\s|$)').hasMatch(codeDirective)) {
        hasAlternative = true;
      }
      if (RegExp(r'^#endif(?:\s|$)').hasMatch(codeDirective)) {
        depth--;
        if (depth == 0) {
          // The code mask proves that this is a real directive rather than a
          // lexical decoy. Permit Xcode/SwiftPM's conventional annotation only
          // for an otherwise exact closing directive.
          final exactClosing = RegExp(
            r'^#endif(?:\s*//\s*os\(macOS\))?$',
          ).hasMatch(sourceDirective);
          if (!hasAlternative && exactClosing && codeDirective == '#endif') {
            removals
              ..add((lines[index].$1, lines[index].$2))
              ..add((lines[nested].$1, lines[nested].$2));
          }
          index = nested;
          break;
        }
      }
    }
  }
  return removals;
}

String _swiftCodeMask(String source) {
  final output = StringBuffer();
  var index = 0;
  var blockCommentDepth = 0;
  var quoteLength = 0;
  var quoteHashCount = 0;
  while (index < source.length) {
    final character = source.codeUnitAt(index);
    final next = index + 1 < source.length ? source.codeUnitAt(index + 1) : -1;

    if (blockCommentDepth > 0) {
      if (character == 0x2f && next == 0x2a) {
        blockCommentDepth++;
        output.write('  ');
        index += 2;
      } else if (character == 0x2a && next == 0x2f) {
        blockCommentDepth--;
        output.write('  ');
        index += 2;
      } else {
        output.write(
          character == 0x0a || character == 0x0d ? source[index] : ' ',
        );
        index++;
      }
      continue;
    }

    if (quoteLength > 0) {
      final quote = '"' * quoteLength;
      final delimiter = '$quote${'#' * quoteHashCount}';
      final closes =
          source.startsWith(delimiter, index) &&
          (quoteHashCount > 0 || !_isEscapedSwiftQuote(source, index));
      if (closes) {
        output.write(' ' * delimiter.length);
        index += delimiter.length;
        quoteLength = 0;
        quoteHashCount = 0;
      } else {
        output.write(
          character == 0x0a || character == 0x0d ? source[index] : ' ',
        );
        index++;
      }
      continue;
    }

    if (character == 0x2f && next == 0x2f) {
      while (index < source.length && source.codeUnitAt(index) != 0x0a) {
        output.write(' ');
        index++;
      }
    } else if (character == 0x2f && next == 0x2a) {
      blockCommentDepth = 1;
      output.write('  ');
      index += 2;
    } else {
      var hashCount = 0;
      while (index + hashCount < source.length &&
          source.codeUnitAt(index + hashCount) == 0x23) {
        hashCount++;
      }
      final quoteStart = index + hashCount;
      if (quoteStart < source.length && source.codeUnitAt(quoteStart) == 0x22) {
        quoteLength = source.startsWith('"""', quoteStart) ? 3 : 1;
        quoteHashCount = hashCount;
        final delimiterLength = hashCount + quoteLength;
        output.write(' ' * delimiterLength);
        index += delimiterLength;
      } else {
        output.write(source[index]);
        index++;
      }
    }
  }
  return output.toString();
}

bool _isEscapedSwiftQuote(String source, int quote) {
  var backslashes = 0;
  for (
    var index = quote - 1;
    index >= 0 && source.codeUnitAt(index) == 0x5c;
    index--
  ) {
    backslashes++;
  }
  return backslashes.isOdd;
}
