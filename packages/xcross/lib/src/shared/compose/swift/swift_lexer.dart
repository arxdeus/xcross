import 'package:meta/meta.dart';

/// What a [SwiftToken] is. Trivia (whitespace, comments) never becomes a
/// token. String and regex literals do, as opaque tokens, so consumers can
/// tell "code was here" without ever looking inside a literal.
@internal
enum SwiftTokenKind {
  /// A plain or backticked (`` `Foo` ``, see [SwiftToken.backticked])
  /// identifier or keyword.
  identifier,

  /// A run of identifier characters starting with a digit.
  number,

  /// Any other single code unit, e.g. `@`, `.`, `{`, `(`.
  punctuation,

  /// `#word`: a compiler directive or macro; [SwiftToken.text] is the word
  /// without hashes and may be empty.
  directive,

  /// A string literal, including multi-line and raw (`#"..."#`) ones.
  string,

  /// An extended regex literal `#/.../#`.
  regex,
}

/// One token of Swift source; see [lexSwift].
@internal
final class SwiftToken {
  const SwiftToken(
    this.kind,
    this.text, {
    required this.start,
    required this.end,
    required this.line,
    required this.newlineBefore,
    this.backticked = false,
  });

  final SwiftTokenKind kind;

  /// Source text; for a backticked identifier the name without backticks,
  /// for a directive the word after the hashes.
  final String text;

  /// Code unit offsets in the source; `end` is exclusive. Consumers compare
  /// them to detect adjacency (`A.B` vs `A .B`).
  final int start;
  final int end;

  /// 1-based physical line of [start].
  final int line;

  /// A newline occurred in the code between the previous token and this one.
  /// Newlines inside comments do not count, because swiftc's statement
  /// boundaries ignore them too.
  final bool newlineBefore;
  final bool backticked;

  bool isPunct(String c) => kind == SwiftTokenKind.punctuation && text == c;

  @override
  String toString() => '$kind($text@$line)';
}

@internal
bool isSwiftIdentChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c > 0x7f;

/// Splits Swift [source] into tokens, skipping trivia.
///
/// This is the single place that knows where Swift code is not code:
/// comments (including nested block comments), string literals (multi-line,
/// raw, escaped), extended regex literals and a leading BOM. Every scanner
/// that looks for declarations builds on it, so a literal form handled here
/// is handled everywhere; two hand-written lexers once disagreed on
/// `#/regex/#` and reported different code.
@internal
List<SwiftToken> lexSwift(String source) => SwiftLexer(source).run();

/// The state machine behind [lexSwift]. Use that function instead.
@internal
final class SwiftLexer {
  SwiftLexer(this.s);

  final String s;
  final out = <SwiftToken>[];
  int i = 0;
  int _lineAt = 0;
  int _line = 1;
  bool _newline = false;

  int get _n => s.length;
  int _at(int k) => k < _n ? s.codeUnitAt(k) : -1;

  int _lineOf(int offset) {
    for (; _lineAt < offset; _lineAt++) {
      if (s.codeUnitAt(_lineAt) == 0x0a) _line++;
    }
    return _line;
  }

  void _emit(
    SwiftTokenKind kind,
    int start,
    String text, {
    bool backticked = false,
  }) {
    out.add(
      SwiftToken(
        kind,
        text,
        start: start,
        end: i,
        line: _lineOf(start),
        newlineBefore: _newline,
        backticked: backticked,
      ),
    );
    _newline = false;
  }

  List<SwiftToken> run() {
    while (i < _n) {
      final c = s.codeUnitAt(i);
      final start = i;
      if (c == 0x0a) {
        _newline = true;
        i++;
      } else if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0xfeff) {
        // 0xFEFF: a UTF-8 BOM decoded at the start of the file is trivia.
        i++;
      } else if (_skipComment()) {
      } else if (c == 0x22) {
        _skipString(0);
        _emit(SwiftTokenKind.string, start, s.substring(start, i));
      } else if (c == 0x23) {
        _hash();
      } else if (c == 0x60 && _backticked()) {
      } else if (isSwiftIdentChar(c)) {
        while (i < _n && isSwiftIdentChar(s.codeUnitAt(i))) {
          i++;
        }
        final digit = c >= 0x30 && c <= 0x39;
        _emit(
          digit ? SwiftTokenKind.number : SwiftTokenKind.identifier,
          start,
          s.substring(start, i),
        );
      } else {
        i++;
        _emit(SwiftTokenKind.punctuation, start, s.substring(start, i));
      }
    }
    return out;
  }

  /// `` `name` `` on one line; false (nothing consumed) otherwise, leaving
  /// the backtick to be a punctuation token.
  bool _backticked() {
    final end = s.indexOf('`', i + 1);
    if (end < 0) return false;
    final name = s.substring(i + 1, end);
    if (name.isEmpty || name.contains('\n')) return false;
    final start = i;
    i = end + 1;
    _emit(SwiftTokenKind.identifier, start, name, backticked: true);
    return true;
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

  /// `#` starts a raw string, an extended regex, or a directive / macro.
  void _hash() {
    final start = i;
    var j = i;
    while (_at(j) == 0x23) {
      j++;
    }
    if (_at(j) == 0x22) {
      i = j;
      _skipString(j - start);
      _emit(SwiftTokenKind.string, start, s.substring(start, i));
      return;
    }
    if (_at(j) == 0x2f) {
      // Extended regex literal `#/.../#`, which may span lines.
      final closer = '/${'#' * (j - start)}';
      final end = s.indexOf(closer, j + 1);
      i = end < 0 ? _n : end + closer.length;
      _emit(SwiftTokenKind.regex, start, s.substring(start, i));
      return;
    }
    i = j;
    while (i < _n && isSwiftIdentChar(s.codeUnitAt(i))) {
      i++;
    }
    _emit(SwiftTokenKind.directive, start, s.substring(j, i));
  }
}
