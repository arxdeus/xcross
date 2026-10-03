import 'dart:io';
import 'package:path/path.dart' as p;

/// Collects the highest iOS availability version annotated directly on one
/// plugin class declaration across Swift and Objective-C sources.
final class PluginClassAvailabilityScanner {
  PluginClassAvailabilityScanner(String pluginClass)
    : _swiftDeclaration = RegExp(
        '\\bclass\\s+${RegExp.escape(pluginClass)}\\b',
      ),
      _objcDeclaration = RegExp(
        '@interface\\s+${RegExp.escape(pluginClass)}\\b',
      );

  static final _lineBreak = RegExp(r'\r?\n');
  static final _swiftDeclarationPrefix = RegExp(
    r'^(?:(?:@[A-Za-z_]\w*(?:\([^)]*\))?|public|open|internal|private|'
    r'fileprivate|final|dynamic|nonisolated)\s+)*$',
  );
  static final _swiftAttributes = RegExp(
    r'^(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s*)+$',
    dotAll: true,
  );
  static final _swiftAvailable = RegExp(
    r'@available\s*\(([^)]*)\)',
    dotAll: true,
  );
  static final _swiftShortIos = RegExp(
    r'(?:^|,)\s*iOS\s+(\d+(?:\.\d+){0,2})(?=\s*,|$)',
  );
  static final _swiftIntroducedIos = RegExp(
    r'(?:^|,)\s*iOS\s*,\s*introduced\s*:\s*(\d+(?:\.\d+){0,2})',
  );
  static final _objcAvailability = RegExp(
    r'API_AVAILABLE\s*\([^;{}]*?\bios\s*\(\s*(\d+(?:\.\d+){0,2})\s*\)',
    dotAll: true,
  );

  final RegExp _swiftDeclaration;
  final RegExp _objcDeclaration;

  /// The highest version seen so far, or null when none was annotated.
  String? requiredVersion;

  void scan(File file) {
    // Preserve line boundaries while masking comments and string literals;
    // examples embedded in Swift multiline strings are not declarations.
    final source = _codeOutsideCommentsAndStrings(file.readAsStringSync());
    final lines = source
        .split(_lineBreak)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    if (p.extension(file.path) == '.h') {
      _scanObjcHeader(lines);
    } else {
      _scanSwift(lines);
    }
  }

  void _consider(String version) {
    if (requiredVersion == null ||
        _compareIosVersions(version, requiredVersion!) > 0) {
      requiredVersion = version;
    }
  }

  /// `API_AVAILABLE(ios(X))` lines directly above, or on, `@interface Class`.
  void _scanObjcHeader(Iterable<String> lines) {
    var pendingAvailability = '';
    for (final line in lines) {
      if (_objcDeclaration.hasMatch(line)) {
        for (final annotation in _objcAvailability.allMatches(
          '$pendingAvailability $line',
        )) {
          _consider(annotation[1]!);
        }
        pendingAvailability = '';
      } else if (line.startsWith('API_AVAILABLE')) {
        pendingAvailability = '$pendingAvailability $line';
      } else {
        pendingAvailability = '';
      }
    }
  }

  /// `@available(iOS X, ...)` attributes attached to `class Class`, either
  /// inline or on the attribute-only lines immediately above it.
  void _scanSwift(Iterable<String> lines) {
    var pendingAttributes = '';
    for (final line in lines) {
      final match = _swiftDeclaration.firstMatch(line);
      if (match != null) {
        final prefix = line.substring(0, match.start);
        if (_swiftDeclarationPrefix.hasMatch(prefix)) {
          if (pendingAttributes.isEmpty ||
              _swiftAttributes.hasMatch(pendingAttributes)) {
            _considerSwiftAttributes('$pendingAttributes $prefix');
          }
          pendingAttributes = '';
          continue;
        }
      }
      pendingAttributes = _nextPendingAttributes(pendingAttributes, line);
    }
  }

  void _considerSwiftAttributes(String attached) {
    for (final annotation in _swiftAvailable.allMatches(attached)) {
      final body = annotation[1]!;
      final version =
          _swiftShortIos.firstMatch(body)?[1] ??
          _swiftIntroducedIos.firstMatch(body)?[1];
      if (version != null) _consider(version);
    }
  }

  /// Accumulate attribute lines, including an attribute whose arguments
  /// span several lines. Anything else, such as an intervening declaration,
  /// owns the attributes above it and resets the accumulation.
  static String _nextPendingAttributes(String pending, String line) {
    final continuesAttribute =
        pending.isNotEmpty && !_swiftAttributes.hasMatch(pending);
    if (!line.startsWith('@') && !continuesAttribute) return '';
    final next = '$pending $line'.trim();
    if (!next.startsWith('@') ||
        next.contains(';') ||
        next.contains('{') ||
        next.contains('}')) {
      return '';
    }
    return next;
  }

  /// Replace comments and string literal contents with spaces, keeping line
  /// breaks so line-oriented declaration matching still works.
  static String _codeOutsideCommentsAndStrings(String source) {
    const code = 0;
    const quoted = 1;
    const multilineQuoted = 3;

    final result = StringBuffer();
    var index = 0;
    var blockDepth = 0;
    var lineComment = false;
    var stringDelimiter = code;
    var escaped = false;

    void mask(int count) {
      for (var offset = 0; offset < count; offset++) {
        final character = source[index + offset];
        result.write(character == '\n' || character == '\r' ? character : ' ');
      }
      index += count;
    }

    while (index < source.length) {
      final character = source[index];
      if (lineComment) {
        if (character == '\n') lineComment = false;
        mask(1);
      } else if (blockDepth > 0) {
        if (source.startsWith('/*', index)) {
          blockDepth++;
          mask(2);
        } else if (source.startsWith('*/', index)) {
          blockDepth--;
          mask(2);
        } else {
          mask(1);
        }
      } else if (stringDelimiter != code) {
        if (!escaped &&
            stringDelimiter == multilineQuoted &&
            source.startsWith('"""', index)) {
          stringDelimiter = code;
          mask(3);
        } else if (!escaped && stringDelimiter == quoted && character == '"') {
          stringDelimiter = code;
          mask(1);
        } else {
          escaped = character == r'\' && !escaped;
          mask(1);
        }
      } else if (source.startsWith('//', index)) {
        lineComment = true;
        mask(2);
      } else if (source.startsWith('/*', index)) {
        blockDepth = 1;
        mask(2);
      } else if (source.startsWith('"""', index)) {
        stringDelimiter = multilineQuoted;
        mask(3);
      } else if (character == '"') {
        stringDelimiter = quoted;
        mask(1);
      } else {
        result.write(character);
        index++;
      }
    }
    return result.toString();
  }

  static int _compareIosVersions(String left, String right) {
    const components = 3;
    final a = left.split('.').map(int.parse).toList();
    final b = right.split('.').map(int.parse).toList();
    for (var index = 0; index < components; index++) {
      final difference =
          (index < a.length ? a[index] : 0) - (index < b.length ? b[index] : 0);
      if (difference != 0) return difference;
    }
    return 0;
  }
}
