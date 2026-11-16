import 'package:test/test.dart';
import 'package:xcross/src/shared/swiftpm/host_source_normalizer.dart';

void main() {
  group('SwiftPmHostSourceNormalizer.removeUnsafeFlags', () {
    test('drops append calls whose only argument is unsafeFlags (#162)', () {
      const manifest = '''
var settings = target.swiftSettings ?? []
settings.append(.enableUpcomingFeature("ExistentialAny"))
settings.append(.unsafeFlags(["-Xfrontend", "-require-explicit-sendable"]))
target.swiftSettings = settings
''';
      final result = SwiftPmHostSourceNormalizer.removeUnsafeFlags(manifest);
      expect(result, isNot(contains('unsafeFlags')));
      expect(result, isNot(contains('append()')));
      expect(
        result,
        contains('settings.append(.enableUpcomingFeature("ExistentialAny"))'),
      );
      expect(result, contains('target.swiftSettings = settings'));
    });

    test('drops optional-chained append of unsafeFlags', () {
      const manifest =
          'package.targets.first?.swiftSettings?.append(.unsafeFlags(["-x"]))\n'
          'let done = true\n';
      expect(
        SwiftPmHostSourceNormalizer.removeUnsafeFlags(manifest).trim(),
        'let done = true',
      );
    });

    test('still removes unsafeFlags list elements', () {
      const manifest =
          'swiftSettings: [.define("A"), .unsafeFlags(["-x"]), .define("B")]';
      expect(
        SwiftPmHostSourceNormalizer.removeUnsafeFlags(
          manifest,
        ).replaceAll(RegExp(r'\s+'), ' '),
        'swiftSettings: [.define("A"), .define("B")]',
      );
    });
  });
}
