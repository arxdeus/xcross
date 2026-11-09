import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/swift/swift_import.dart';

/// Swift access-level modifiers allowed before `import` since Swift 6.
const _accessModifiers = {
  'public',
  'internal',
  'private',
  'fileprivate',
  'package',
};

/// `import <kind> Module.symbol` scopes the import to one declaration.
const _importKinds = {
  'typealias',
  'struct',
  'class',
  'enum',
  'protocol',
  'let',
  'var',
  'func',
};

/// Finds the `import` declarations of one Swift [source].
///
/// A regex cannot do this reliably: `import` also appears in comments, string
/// literals (including multi-line and raw ones), identifiers such as
/// `importer`, and is preceded by attributes (`@testable`), access modifiers
/// (`public import`) or followed by an import kind (`import struct X.Y`).
/// Discovery decides what the build requires from this list, so a false
/// positive would fail a build and a false negative would hide a missing
/// module. This is therefore a small lexer that only understands trivia,
/// strings, `#if` nesting and the import grammar, nothing else of Swift.
///
/// Imports inside any `#if` block are reported `conditional`, because the
/// common `#if canImport(X)` pattern means the module may legitimately not
/// exist on the target SDK.
///
/// Differentially tested against `swiftc -frontend -dump-parse`. Known,
/// intentional differences: lines are physical lines (swiftc honours
/// `#sourceLocation`), and in invalid code where `import` follows an
/// expression on the same line without `;` (`let x = 1 import A`) swiftc's
/// error recovery still records the import while this scanner does not.
/// Such a file fails to compile anyway.
@internal
List<SwiftImport> scanSwiftImports(String source, {required String path}) =>
    SwiftImportLexer(source, path).scan();

bool _isIdentChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c > 0x7f;

bool _isIdentStart(int c) => _isIdentChar(c) && !(c >= 0x30 && c <= 0x39);

/// The state machine behind [scanSwiftImports]. Use that function instead.
@internal
final class SwiftImportLexer {
  SwiftImportLexer(this.s, this.path);

  final String s;
  final String path;
  int i = 0;
  int _lineAt = 0;
  int _line = 1;
  int ifDepth = 0;

  /// `{` nesting. swiftc only accepts imports at file scope, so an `import`
  /// inside a body is an error and is not recorded.
  int braceDepth = 0;

  /// Only attributes and access modifiers seen since the statement started,
  /// so an `import` word here really begins an import declaration.
  bool prefixOk = true;

  /// The last token was an attribute: a newline then keeps [prefixOk]
  /// because `@testable\nimport X` is legal.
  bool afterAttribute = false;

  int get _n => s.length;
  int _at(int k) => k < _n ? s.codeUnitAt(k) : -1;

  int _lineOf(int offset) {
    for (; _lineAt < offset; _lineAt++) {
      if (s.codeUnitAt(_lineAt) == 0x0a) _line++;
    }
    return _line;
  }

  List<SwiftImport> scan() {
    final out = <SwiftImport>[];
    while (i < _n) {
      final c = s.codeUnitAt(i);
      if (c == 0x0a) {
        if (!afterAttribute) prefixOk = true;
        i++;
      } else if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0xfeff) {
        // 0xFEFF: a UTF-8 BOM decoded at the start of the file is trivia.
        i++;
      } else if (_skipComment()) {
        // Comments are trivia and do not affect statement state.
      } else if (c == 0x3b || c == 0x7b || c == 0x7d) {
        if (c == 0x7b) braceDepth++;
        if (c == 0x7d && braceDepth > 0) braceDepth--;
        prefixOk = true;
        afterAttribute = false;
        i++;
      } else if (c == 0x22) {
        _skipString(0);
        _other();
      } else if (c == 0x23) {
        _directive();
      } else if (c == 0x40) {
        _attribute();
      } else if (_isIdentStart(c)) {
        final start = i;
        final word = _word();
        if (word == 'import' && prefixOk && !_afterDot(start)) {
          final imp = _parseImport(start);
          if (imp != null && braceDepth == 0) out.add(imp);
          prefixOk = false;
          afterAttribute = false;
        } else if (prefixOk && _accessModifiers.contains(word)) {
          afterAttribute = false;
        } else {
          _other();
        }
      } else {
        _other();
        i++;
      }
    }
    return out;
  }

  void _other() {
    prefixOk = false;
    afterAttribute = false;
  }

  bool _afterDot(int start) => start > 0 && s.codeUnitAt(start - 1) == 0x2e;

  String _word() {
    final start = i;
    while (i < _n && _isIdentChar(s.codeUnitAt(i))) {
      i++;
    }
    return s.substring(start, i);
  }

  /// Skips a `//` or (nested) `/* */` comment at [i]; false if none there.
  bool _skipComment() {
    if (_at(i) != 0x2f) return false;
    if (_at(i + 1) == 0x2f) {
      while (i < _n && s.codeUnitAt(i) != 0x0a) {
        i++;
      }
      return true;
    }
    if (_at(i + 1) == 0x2a) {
      var depth = 0;
      while (i < _n) {
        if (_at(i) == 0x2f && _at(i + 1) == 0x2a) {
          depth++;
          i += 2;
        } else if (_at(i) == 0x2a && _at(i + 1) == 0x2f) {
          depth--;
          i += 2;
          if (depth == 0) break;
        } else {
          i++;
        }
      }
      return true;
    }
    return false;
  }

  /// Skips a string literal starting at the opening quote [i], with [hashes]
  /// leading `#` of a raw string already consumed.
  void _skipString(int hashes) {
    final multiline = _at(i + 1) == 0x22 && _at(i + 2) == 0x22;
    i += multiline ? 3 : 1;
    final closer = '#' * hashes;
    while (i < _n) {
      final c = s.codeUnitAt(i);
      if (c == 0x5c && s.startsWith(closer, i + 1)) {
        i += 2 + hashes;
      } else if (c == 0x22) {
        final quotes = multiline ? '"""' : '"';
        if (s.startsWith(quotes, i) &&
            s.startsWith(closer, i + quotes.length)) {
          i += quotes.length + hashes;
          return;
        }
        i++;
      } else if (c == 0x0a && !multiline) {
        // Unterminated single-line string: recover at the line end.
        return;
      } else {
        i++;
      }
    }
  }

  void _directive() {
    var j = i;
    while (_at(j) == 0x23) {
      j++;
    }
    if (_at(j) == 0x22) {
      final hashes = j - i;
      i = j;
      _skipString(hashes);
      _other();
      return;
    }
    if (j > i && _at(j) == 0x2f) {
      // Extended regex literal `#/.../#`, which may span lines.
      final closer = '/${'#' * (j - i)}';
      final end = s.indexOf(closer, j + 1);
      i = end < 0 ? _n : end + closer.length;
      _other();
      return;
    }
    i = j;
    final word = _word();
    switch (word) {
      case 'if':
        ifDepth++;
      case 'endif':
        if (ifDepth > 0) ifDepth--;
    }
    // The rest of the directive line is a condition, not a declaration.
    _other();
  }

  void _attribute() {
    i++;
    _word();
    var j = i;
    while (_at(j) == 0x20 || _at(j) == 0x09) {
      j++;
    }
    if (_at(j) == 0x28) {
      var depth = 0;
      i = j;
      while (i < _n) {
        final c = s.codeUnitAt(i);
        if (c == 0x22) {
          _skipString(0);
          continue;
        }
        i++;
        if (c == 0x28) depth++;
        if (c == 0x29 && --depth == 0) break;
      }
    }
    afterAttribute = true;
  }

  void _skipTrivia() {
    while (i < _n) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0x0a) {
        i++;
      } else if (!_skipComment()) {
        return;
      }
    }
  }

  /// An identifier at [i], or a backticked one (`` import `Foo` `` names
  /// module `Foo`). Null when neither is there.
  String? _moduleName() {
    if (_at(i) == 0x60) {
      final end = s.indexOf('`', i + 1);
      if (end < 0 || s.substring(i + 1, end).contains('\n')) return null;
      final name = s.substring(i + 1, end);
      i = end + 1;
      return name.isEmpty ? null : name;
    }
    return _isIdentStart(_at(i)) ? _word() : null;
  }

  SwiftImport? _parseImport(int keywordStart) {
    _skipTrivia();
    var word = _moduleName();
    if (word == null) return null;
    if (_importKinds.contains(word)) {
      final save = i;
      _skipTrivia();
      final scoped = _moduleName();
      if (scoped != null) {
        // A kinded import needs `Module.symbol` with the dot right after
        // the module name; swiftc rejects `import struct A` or `A\n.B`.
        if (_at(i) != 0x2e) return null;
        word = scoped;
      } else {
        i = save;
      }
    }
    return SwiftImport(
      word,
      path: path,
      line: _lineOf(keywordStart),
      conditional: ifDepth > 0,
    );
  }
}
