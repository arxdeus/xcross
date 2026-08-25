import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/swift_package_host_patches.dart';

void main() {
  group('exposeMacOSPackageGraphEntries', () {
    test('unwraps graph arrays without package-specific markers', () {
      const input = '''
#if os(macOS)
let hostOnly = true
#endif
func products() -> [Product] {
  #if os(macOS)
  return makeProducts()
  #endif
}
func dependencies() -> [Package.Dependency] {
  #if os(macOS)
  return makeDependencies()
  #endif
}
func targets() -> [ Target ] {
  #if os(macOS)
  return makeTargets()
  #endif
}
''';

      final patched = exposeMacOSPackageGraphEntries(input);

      expect(patched, startsWith('#if os(macOS)\nlet hostOnly'));
      expect(patched, contains('  return makeProducts()'));
      expect(patched, contains('  return makeDependencies()'));
      expect(patched, contains('  return makeTargets()'));
      expect('#if os(macOS)'.allMatches(patched), hasLength(1));
      expect(exposeMacOSPackageGraphEntries(patched), patched);
    });

    test('preserves nested directives and ignores lexical decoys', () {
      const input = '''
let text = "func fake() -> [Product] { #if os(macOS) }"
/* func fakeToo() -> [Target] { #if os(macOS) } */
func products(argument: () -> Void = { print("}") }) -> [Product] {
  #if os(macOS)
  #if canImport(Something)
  return first
  #else
  return second
  #endif
  #endif
}
func unrelated() -> [String] {
  #if os(macOS)
  return []
  #endif
}
''';

      final patched = exposeMacOSPackageGraphEntries(input);

      expect(patched, contains('#if canImport(Something)'));
      expect(patched, contains('#else\n  return second\n  #endif'));
      expect(
        patched,
        contains('func unrelated() -> [String] {\n  #if os(macOS)'),
      );
      expect(patched, contains('"func fake() -> [Product] { #if os(macOS) }"'));
    });

    test('ignores directives and braces in arbitrary-hash raw strings', () {
      const input = '''
func products() -> [Product] {
  let single = ####"} #if os(macOS) #endif"####
  let multiline = ##"""
  }
  #if os(macOS)
  #endif
  """##
  #if os(macOS)
  return makeProducts()
  #endif
}
''';

      final patched = exposeMacOSPackageGraphEntries(input);

      expect(patched, contains('####"} #if os(macOS) #endif"####'));
      expect(patched, contains('  #if os(macOS)\n  #endif\n  """##'));
      expect(patched, contains('  return makeProducts()'));
      expect('#if os(macOS)'.allMatches(patched), hasLength(2));
    });

    test('requires exact standalone paired directives', () {
      const input = '''
func products() -> [Product] {
  #if os(macOS) // explanation
  let annotated = true
  #endif
  #if os(macOS)
  let alternative = true
  #else
  let fallback = true
  #endif
  #if os(macOS)
  let exact = true
  #endif // os(macOS)
}
''';

      final patched = exposeMacOSPackageGraphEntries(input);
      expect(
        patched,
        isNot(contains('let exact = true\n  #endif // os(macOS)')),
      );
      expect(patched, contains('#if os(macOS) // explanation'));
      expect(patched, contains('#else\n  let fallback = true'));
      expect(exposeMacOSPackageGraphEntries(patched), patched);
    });

    test('accepts annotated real closing directives while preserving CRLF', () {
      const input =
          'func targets() -> [Target] {\r\n'
          '  #if os(macOS)\r\n'
          '  return []\r\n'
          '  #endif // os(macOS)\r\n'
          '}\r\n';
      const expected = 'func targets() -> [Target] {\r\n  return []\r\n}\r\n';

      final patched = exposeMacOSPackageGraphEntries(input);

      expect(patched, expected);
      expect(exposeMacOSPackageGraphEntries(patched), expected);
    });
  });
}
