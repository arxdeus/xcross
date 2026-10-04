import 'dart:convert';

final class SwiftPmRemoteBinaryTarget {
  const SwiftPmRemoteBinaryTarget({
    required this.name,
    required this.url,
    required this.checksum,
    required this.start,
    required this.end,
  });

  final String name;
  final Uri url;
  final String checksum;
  final int start;
  final int end;
}

abstract final class SwiftPmBinaryTargetManifest {
  static final _checksumPattern = RegExp(r'^[0-9a-fA-F]{64}$');

  static List<SwiftPmRemoteBinaryTarget> discover(String source) {
    final targets = <SwiftPmRemoteBinaryTarget>[];
    final parser = SwiftManifestParser(source);

    for (final declaration in parser.binaryTargetDeclarations()) {
      final name = declaration.name;
      final urlText = declaration.url;
      final checksum = declaration.checksum;
      final url = urlText == null ? null : Uri.tryParse(urlText);

      if (name == null ||
          checksum == null ||
          url == null ||
          !_isRemoteZipUrl(url) ||
          !_checksumPattern.hasMatch(checksum)) {
        continue;
      }

      targets.add(
        SwiftPmRemoteBinaryTarget(
          name: name,
          url: url,
          checksum: checksum,
          start: declaration.start,
          end: declaration.end,
        ),
      );
    }
    return targets;
  }

  static bool _isRemoteZipUrl(Uri url) {
    final isWebUrl = url.scheme == 'https' || url.scheme == 'http';
    return isWebUrl &&
        url.hasAuthority &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty &&
        url.path.toLowerCase().endsWith('.zip');
  }

  static String rewriteToLocalPaths(
    String source,
    Map<SwiftPmRemoteBinaryTarget, String> relativePaths,
  ) {
    final discovered = discover(source);
    for (final requested in relativePaths.keys) {
      final belongs = discovered.any(
        (target) =>
            target.start == requested.start &&
            target.end == requested.end &&
            target.name == requested.name &&
            target.url == requested.url &&
            target.checksum == requested.checksum,
      );
      if (!belongs) {
        throw ArgumentError.value(
          requested,
          'relativePaths',
          'Target not in source',
        );
      }
    }

    var rewritten = source;
    final replacements = relativePaths.entries.toList()
      ..sort((left, right) => right.key.start.compareTo(left.key.start));
    for (final entry in replacements) {
      final target = entry.key;
      final replacement =
          '.binaryTarget(name: ${jsonEncode(target.name)}, path: ${jsonEncode(entry.value)})';
      rewritten = rewritten.replaceRange(target.start, target.end, replacement);
    }
    return rewritten;
  }
}

final class BinaryTargetDeclaration {
  const BinaryTargetDeclaration({
    required this.name,
    required this.url,
    required this.checksum,
    required this.start,
    required this.end,
  });

  final String? name;
  final String? url;
  final String? checksum;
  final int start;
  final int end;
}

final class SwiftManifestParser {
  SwiftManifestParser(this.source) : _code = _buildCodeMask(source);

  static const _binaryTargetCall = '.binaryTarget';
  static const _recognizedArguments = {'name', 'url', 'checksum'};

  final String source;
  final List<bool> _code;

  List<BinaryTargetDeclaration> binaryTargetDeclarations() {
    final declarations = <BinaryTargetDeclaration>[];

    for (var callStart = 0; callStart < source.length; callStart++) {
      final openingParenthesis = _binaryTargetOpeningAt(callStart);
      if (openingParenthesis == null) continue;

      final closingParenthesis = _matchingParenthesis(openingParenthesis);
      if (closingParenthesis == null) continue;

      final arguments = _directStringArguments(
        openingParenthesis + 1,
        closingParenthesis,
      );
      declarations.add(
        BinaryTargetDeclaration(
          name: arguments['name'],
          url: arguments['url'],
          checksum: arguments['checksum'],
          start: callStart,
          end: closingParenthesis + 1,
        ),
      );
      callStart = closingParenthesis;
    }
    return declarations;
  }

  int? _binaryTargetOpeningAt(int callStart) {
    if (!_code[callStart] || !source.startsWith(_binaryTargetCall, callStart)) {
      return null;
    }

    final callNameEnd = callStart + _binaryTargetCall.length;
    if (!_isCodeRange(callStart, callNameEnd) ||
        callNameEnd < source.length &&
            _isIdentifier(source.codeUnitAt(callNameEnd))) {
      return null;
    }

    final openingParenthesis = _skipWhitespace(callNameEnd, source.length);
    if (openingParenthesis == source.length ||
        source[openingParenthesis] != '(' ||
        !_code[openingParenthesis]) {
      return null;
    }
    return openingParenthesis;
  }

  Map<String, String> _directStringArguments(int start, int end) {
    final arguments = <String, String>{};
    var argumentStart = start;
    var parenthesisDepth = 0;
    var bracketDepth = 0;
    var braceDepth = 0;

    void parseArgumentEndingAt(int argumentEnd) {
      final argument = _directStringArgument(argumentStart, argumentEnd);
      if (argument != null) arguments[argument.label] = argument.value;
    }

    for (var index = start; index < end; index++) {
      if (!_code[index]) continue;
      switch (source[index]) {
        case '(':
          parenthesisDepth++;
        case ')':
          parenthesisDepth--;
        case '[':
          bracketDepth++;
        case ']':
          bracketDepth--;
        case '{':
          braceDepth++;
        case '}':
          braceDepth--;
        case ','
            when parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0:
          parseArgumentEndingAt(index);
          argumentStart = index + 1;
      }
    }
    parseArgumentEndingAt(end);
    return arguments;
  }

  ({String label, String value})? _directStringArgument(int start, int end) {
    final labelStart = _skipWhitespace(start, end);
    var cursor = labelStart;
    while (cursor < end && _isIdentifier(source.codeUnitAt(cursor))) {
      cursor++;
    }

    final label = source.substring(labelStart, cursor);
    if (!_recognizedArguments.contains(label)) return null;

    cursor = _skipWhitespace(cursor, end);
    if (cursor == end || source[cursor] != ':') return null;

    final valueStart = _skipWhitespace(cursor + 1, end);
    final value = _parseStringLiteral(valueStart, end);
    return value == null ? null : (label: label, value: value);
  }

  String? _parseStringLiteral(int start, int argumentEnd) {
    var hashCount = 0;
    while (start + hashCount < argumentEnd &&
        source[start + hashCount] == '#') {
      hashCount++;
    }

    final openingQuote = start + hashCount;
    if (openingQuote >= argumentEnd || source[openingQuote] != '"') {
      return null;
    }

    final isMultiline = source.startsWith('"""', openingQuote);
    final openingLength = isMultiline ? 3 : 1;
    final closingDelimiter = '${isMultiline ? '"""' : '"'}${'#' * hashCount}';
    final contentStart = openingQuote + openingLength;
    final contentEnd = _skipTrailingWhitespace(contentStart, argumentEnd);
    if (!source.substring(start, contentEnd).endsWith(closingDelimiter)) {
      return null;
    }

    final valueEnd = contentEnd - closingDelimiter.length;
    if (valueEnd < contentStart) return null;

    var value = source.substring(contentStart, valueEnd);
    final rawEscape = '\\${'#' * hashCount}';
    if (value.contains('$rawEscape(') ||
        hashCount > 0 && value.contains(rawEscape)) {
      return null;
    }

    if (isMultiline) {
      final closingLineStart = source.lastIndexOf('\n', valueEnd - 1) + 1;
      final closingIndent = source.substring(closingLineStart, valueEnd);
      if (closingIndent.trim().isEmpty && closingLineStart != valueEnd) {
        return null;
      }
      value = _removeMultilineBoundaryNewlines(value);
    }

    if (hashCount > 0) return value;
    try {
      return jsonDecode('"${value.replaceAll(r'\/', '/')}"') as String;
    } on FormatException {
      return null;
    }
  }

  String _removeMultilineBoundaryNewlines(String value) {
    var result = value;
    if (result.startsWith('\r\n')) {
      result = result.substring(2);
    } else if (result.startsWith('\n')) {
      result = result.substring(1);
    }
    if (result.endsWith('\r\n')) {
      result = result.substring(0, result.length - 2);
    } else if (result.endsWith('\n')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  int? _matchingParenthesis(int openingParenthesis) {
    var depth = 0;
    for (var index = openingParenthesis; index < source.length; index++) {
      if (!_code[index]) continue;
      if (source[index] == '(') depth++;
      if (source[index] == ')' && --depth == 0) return index;
    }
    return null;
  }

  int _skipWhitespace(int start, int end) {
    var cursor = start;
    while (cursor < end && _isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    return cursor;
  }

  int _skipTrailingWhitespace(int start, int end) {
    var cursor = end;
    while (cursor > start && _isWhitespace(source.codeUnitAt(cursor - 1))) {
      cursor--;
    }
    return cursor;
  }

  bool _isCodeRange(int start, int end) {
    for (var index = start; index < end; index++) {
      if (!_code[index]) return false;
    }
    return true;
  }

  static List<bool> _buildCodeMask(String source) {
    final code = List<bool>.filled(source.length, true);
    var index = 0;
    while (index < source.length) {
      if (source.startsWith('//', index)) {
        final commentStart = index;
        index += 2;
        while (index < source.length && source[index] != '\n') {
          index++;
        }
        _mask(code, commentStart, index);
        continue;
      }
      if (source.startsWith('/*', index)) {
        final commentStart = index;
        var depth = 1;
        index += 2;
        while (index < source.length && depth > 0) {
          if (source.startsWith('/*', index)) {
            depth++;
            index += 2;
          } else if (source.startsWith('*/', index)) {
            depth--;
            index += 2;
          } else {
            index++;
          }
        }
        _mask(code, commentStart, index);
        continue;
      }

      final hashCount = _rawStringHashCount(source, index);
      final openingQuote = index + hashCount;
      if (openingQuote < source.length && source[openingQuote] == '"') {
        final stringStart = index;
        final isMultiline = source.startsWith('"""', openingQuote);
        final openingLength = isMultiline ? 3 : 1;
        final closingDelimiter =
            '${isMultiline ? '"""' : '"'}${'#' * hashCount}';
        index = openingQuote + openingLength;
        while (index < source.length) {
          final isClosingDelimiter =
              source.startsWith(closingDelimiter, index) &&
              (hashCount == 0
                  ? !_isEscaped(source, index)
                  : !_isRawEscapedDelimiter(source, index, hashCount));
          if (isClosingDelimiter) {
            index += closingDelimiter.length;
            break;
          }
          index++;
        }
        _mask(code, stringStart, index);
        continue;
      }
      index++;
    }
    return code;
  }

  static int _rawStringHashCount(String source, int start) {
    var hashCount = 0;
    while (start + hashCount < source.length &&
        source[start + hashCount] == '#') {
      hashCount++;
    }
    return hashCount;
  }

  static bool _isRawEscapedDelimiter(String source, int index, int hashCount) {
    final escapeStart = index - hashCount - 1;
    return escapeStart >= 0 &&
        source[escapeStart] == r'\' &&
        source.substring(escapeStart + 1, index) == '#' * hashCount;
  }

  static bool _isEscaped(String source, int index) {
    var slashCount = 0;
    for (
      var cursor = index - 1;
      cursor >= 0 && source[cursor] == r'\';
      cursor--
    ) {
      slashCount++;
    }
    return slashCount.isOdd;
  }

  static bool _isIdentifier(int character) =>
      character >= 48 && character <= 57 ||
      character >= 65 && character <= 90 ||
      character >= 97 && character <= 122 ||
      character == 95;

  static bool _isWhitespace(int character) =>
      character == 0x20 ||
      character == 0x09 ||
      character == 0x0a ||
      character == 0x0d;

  static void _mask(List<bool> code, int start, int end) {
    for (var index = start; index < end; index++) {
      code[index] = false;
    }
  }
}
