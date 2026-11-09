import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/swift/swift_import.dart';
import 'package:xcross/src/shared/compose/swift/swift_lexer.dart';

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

/// The state machine behind [scanSwiftImports]. Use that function instead.
///
/// Works on [lexSwift] tokens, so it never has to know about comments or
/// literals; it only tracks statement starts, `{}` and `#if` nesting.
@internal
final class SwiftImportLexer {
  SwiftImportLexer(this.s, this.path) : t = lexSwift(s);

  final String s;
  final String path;
  final List<SwiftToken> t;
  int k = 0;
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

  /// Index of a token whose preceding newline was already consumed while
  /// parsing an import, so it must not restart a statement.
  int _newlineSeen = -1;

  List<SwiftImport> scan() {
    final out = <SwiftImport>[];
    while (k < t.length) {
      final tok = t[k];
      if (tok.newlineBefore && k != _newlineSeen && !afterAttribute) {
        prefixOk = true;
      }
      k++;
      switch (tok.kind) {
        case SwiftTokenKind.punctuation:
          final c = tok.text;
          if (c == ';' || c == '{' || c == '}') {
            if (c == '{') braceDepth++;
            if (c == '}' && braceDepth > 0) braceDepth--;
            prefixOk = true;
            afterAttribute = false;
          } else if (c == '@') {
            _attribute(tok);
          } else {
            _other();
          }
        case SwiftTokenKind.directive:
          if (tok.text == 'if') ifDepth++;
          if (tok.text == 'endif' && ifDepth > 0) ifDepth--;
          // The rest of the directive line is a condition, not a declaration.
          _other();
        case SwiftTokenKind.identifier when !tok.backticked:
          final afterDot = tok.start > 0 && s.codeUnitAt(tok.start - 1) == 0x2e;
          if (tok.text == 'import' && prefixOk && !afterDot) {
            final imp = _parseImport(tok);
            if (imp != null && braceDepth == 0) out.add(imp);
            prefixOk = false;
            afterAttribute = false;
          } else if (prefixOk && _accessModifiers.contains(tok.text)) {
            afterAttribute = false;
          } else {
            _other();
          }
        default:
          _other();
      }
    }
    return out;
  }

  void _other() {
    prefixOk = false;
    afterAttribute = false;
  }

  SwiftToken? get _peek => k < t.length ? t[k] : null;

  void _attribute(SwiftToken at) {
    var end = at.end;
    final name = _peek;
    if (name != null &&
        name.start == end &&
        !name.backticked &&
        (name.kind == SwiftTokenKind.identifier ||
            name.kind == SwiftTokenKind.number)) {
      end = name.end;
      k++;
    }
    final paren = _peek;
    if (paren != null &&
        paren.isPunct('(') &&
        s
            .substring(end, paren.start)
            .codeUnits
            .every((c) => c == 0x20 || c == 0x09)) {
      var depth = 0;
      while (k < t.length) {
        final x = t[k++];
        if (x.isPunct('(')) depth++;
        if (x.isPunct(')') && --depth == 0) break;
      }
    }
    afterAttribute = true;
  }

  /// The token at [k] as a module name (plain or backticked identifier),
  /// consuming it; its leading newline is trivia inside the declaration.
  String? _moduleName() {
    final x = _peek;
    if (x == null) return null;
    _newlineSeen = k;
    if (x.kind != SwiftTokenKind.identifier) return null;
    k++;
    return x.text;
  }

  SwiftImport? _parseImport(SwiftToken keyword) {
    var word = _moduleName();
    if (word == null) return null;
    if (_importKinds.contains(word)) {
      final save = k;
      final scoped = _moduleName();
      if (scoped != null) {
        // A kinded import needs `Module.symbol` with the dot right after
        // the module name; swiftc rejects `import struct A` or `A\n.B`.
        final end = t[k - 1].end;
        if (end >= s.length || s.codeUnitAt(end) != 0x2e) return null;
        word = scoped;
      } else {
        k = save;
        _newlineSeen = -1;
      }
    }
    return SwiftImport(
      word,
      path: path,
      line: keyword.line,
      conditional: ifDepth > 0,
    );
  }
}
