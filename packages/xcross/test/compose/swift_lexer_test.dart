import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/kmp_entry_discovery.dart';
import 'package:xcross/src/shared/compose/swift/swift_lexer.dart';

void main() {
  List<String> code(String s) => [
    for (final t in lexSwift(s))
      if (t.kind != SwiftTokenKind.string && t.kind != SwiftTokenKind.regex)
        t.text,
  ];

  group('lexSwift', () {
    test('skips comments, nested comments, strings and regex', () {
      const src = r'''
// import A
/* x /* import B */ y */
let s = "import C" + #"\"# + """
import D
"""
let r = #/import E/#
''';
      expect(code(src), ['let', 's', '=', '+', '+', 'let', 'r', '=']);
    });

    test('reports 1-based lines and newline flags', () {
      final t = lexSwift('\ufeffa\r\n/* \n */ b\n#if X');
      expect(
        [for (final x in t) '${x.text}@${x.line}'],
        ['a@1', 'b@3', 'if@4', 'X@4'],
      );
      expect(t[1].newlineBefore, isTrue);
      expect(t[0].newlineBefore, isFalse);
      expect(t[2].kind, SwiftTokenKind.directive);
    });

    test('backticked identifiers keep the bare name', () {
      final t = lexSwift('import `Foo`');
      expect(t.last.text, 'Foo');
      expect(t.last.backticked, isTrue);
    });

    test('import scanner and app host agree on regex literals', () {
      // Both consumers sit on lexSwift, so a regex hides `@main` too.
      expect(tokenizeSwiftCode('#/@main struct A: App {}/#'), isEmpty);
      expect(tokenizeSwiftCode('x = SwiftUI.App . b'), [
        'x',
        '=',
        'SwiftUI.App',
        '.',
        'b',
      ]);
    });
  });
}
