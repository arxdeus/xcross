import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/swift/swift_import_scanner.dart';

void main() {
  List<(String, int, bool)> scan(String src) => [
    for (final i in scanSwiftImports(src, path: 'A.swift'))
      (i.module, i.line, i.conditional),
  ];
  List<String> mods(String src) => [for (final i in scan(src)) i.$1];

  test('plain, submodule and kinded imports yield top-level module', () {
    expect(
      mods(
        'import Foundation\nimport UIKit.UIGestureRecognizerSubclass\n'
        'import struct SwiftUI.Color\nimport func Darwin.sqrt\n',
      ),
      ['Foundation', 'UIKit', 'SwiftUI', 'Darwin'],
    );
  });

  test('attributes, including multiple and on previous line', () {
    expect(
      mods(
        '@testable import A\n@_exported import B\n@preconcurrency import C\n'
        '@_implementationOnly import D\n@_spi(Foo) import E\n'
        '@testable @_exported import F\n@testable\nimport G\n',
      ),
      ['A', 'B', 'C', 'D', 'E', 'F', 'G'],
    );
  });

  test('access modifiers', () {
    expect(
      mods(
        'public import A\ninternal import B\nprivate import C\n'
        'fileprivate import D\npackage import E\n@preconcurrency public import F',
      ),
      ['A', 'B', 'C', 'D', 'E', 'F'],
    );
  });

  test('semicolons, indentation, trailing comments and lines', () {
    expect(scan('  import A; import B // c\n\n\timport C /* x */'), [
      ('A', 1, false),
      ('B', 1, false),
      ('C', 3, false),
    ]);
  });

  test('ignores comments, strings and look-alike identifiers', () {
    expect(
      mods('''
// import A
/* import B /* nested import C */ import D */
let s = "import E"
let m = """
import F
"""
let r = #"import G "quoted" "#
let importer = 1
let reimport = 2
foo.import
import Real
'''),
      ['Real'],
    );
  });

  test('conditional imports, nested and else branches', () {
    expect(
      scan(
        'import A\n#if canImport(UIKit)\nimport UIKit\n#if os(iOS)\nimport B\n'
        '#endif\n#else\nimport C\n#endif\nimport D\n',
      ),
      [
        ('A', 1, false),
        ('UIKit', 3, true),
        ('B', 5, true),
        ('C', 8, true),
        ('D', 10, false),
      ],
    );
  });

  test('handles a BOM, backticked names and CRLF', () {
    expect(
      scan(
        '\uFEFFimport Foundation\r\nimport `Foo`\r\nimport struct `B`.C\r\n',
      ),
      [('Foundation', 1, false), ('Foo', 2, false), ('B', 3, false)],
    );
  });
}
