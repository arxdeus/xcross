import 'package:meta/meta.dart';

/// Recursive-descent parser for the OpenStep property list dialect Xcode
/// writes. Handles quoted strings with escapes, `//` comments, `/* */`
/// comments, dictionaries, and arrays.
@internal
final class PbxParser {
  PbxParser(this._source);

  final String _source;
  int _offset = 0;

  /// Parse the whole file: an optional `// !$*UTF8*$!` header then one dict.
  Map<String, Object?> parseArchive() {
    _skipTrivia();
    final value = _parseValue();
    if (value is! Map<String, Object?>) {
      throw const FormatException('pbxproj root is not a dictionary');
    }
    return value;
  }

  Object? _parseValue() {
    _skipTrivia();
    if (_offset >= _source.length) {
      throw const FormatException('unexpected end of pbxproj');
    }
    return switch (_source[_offset]) {
      '{' => _parseDictionary(),
      '(' => _parseArray(),
      '"' => _parseQuotedString(),
      _ => _parseBareString(),
    };
  }

  Map<String, Object?> _parseDictionary() {
    _expect('{');
    final result = <String, Object?>{};
    while (true) {
      _skipTrivia();
      if (_peek() == '}') {
        _offset++;
        return result;
      }
      final key = _parseValue();
      if (key is! String) {
        throw const FormatException('pbxproj dictionary key is not a string');
      }
      _skipTrivia();
      _expect('=');
      result[key] = _parseValue();
      _skipTrivia();
      // Xcode always writes the trailing semicolon; tolerate its absence.
      if (_peek() == ';') _offset++;
    }
  }

  List<Object?> _parseArray() {
    _expect('(');
    final result = <Object?>[];
    while (true) {
      _skipTrivia();
      if (_peek() == ')') {
        _offset++;
        return result;
      }
      result.add(_parseValue());
      _skipTrivia();
      if (_peek() == ',') _offset++;
    }
  }

  String _parseQuotedString() {
    _expect('"');
    final buffer = StringBuffer();
    while (_offset < _source.length) {
      final char = _source[_offset++];
      if (char == '"') return buffer.toString();
      if (char != r'\') {
        buffer.write(char);
        continue;
      }
      if (_offset >= _source.length) break;
      final escaped = _source[_offset++];
      buffer.write(switch (escaped) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        _ => escaped,
      });
    }
    throw const FormatException('unterminated string in pbxproj');
  }

  /// A bare token: everything up to whitespace or a structural character.
  String _parseBareString() {
    final start = _offset;
    while (_offset < _source.length) {
      final char = _source[_offset];
      if (char.trim().isEmpty) break;
      if ('{}()=,;"'.contains(char)) break;
      // A `/` starts a comment only as `//` or `/*`; otherwise it's a path.
      if (char == '/' && _offset + 1 < _source.length) {
        final next = _source[_offset + 1];
        if (next == '/' || next == '*') break;
      }
      _offset++;
    }
    if (start == _offset) {
      throw FormatException('unexpected character in pbxproj at $_offset');
    }
    return _source.substring(start, _offset);
  }

  void _expect(String char) {
    _skipTrivia();
    if (_peek() != char) {
      throw FormatException('expected "$char" in pbxproj at $_offset');
    }
    _offset++;
  }

  String? _peek() => _offset < _source.length ? _source[_offset] : null;

  /// Skip whitespace, `// line` comments, and `/* block */` comments.
  void _skipTrivia() {
    while (_offset < _source.length) {
      final char = _source[_offset];
      if (char.trim().isEmpty) {
        _offset++;
        continue;
      }
      if (char != '/' || _offset + 1 >= _source.length) return;
      final next = _source[_offset + 1];
      if (next == '/') {
        final end = _source.indexOf('\n', _offset);
        _offset = end == -1 ? _source.length : end + 1;
      } else if (next == '*') {
        final end = _source.indexOf('*/', _offset + 2);
        _offset = end == -1 ? _source.length : end + 2;
      } else {
        return;
      }
    }
  }
}
