import 'package:test/test.dart';
import 'package:repo_analyzer/src/conventions.dart';

SourceLocation _at(String relative) => SourceLocation.of(
  '/w/packages/pkg/$relative',
  packageRoot: '/w/packages/pkg',
);

void main() {
  group('SourceLocation', () {
    test('composition roots', () {
      for (final path in [
        'lib/composition/native_host.dart',
        'lib/src/composition/cli/runner.dart',
        'bin/xcross.dart',
        'tool/build.dart',
        'hook/build.dart',
      ]) {
        expect(_at(path).isCompositionRoot, isTrue, reason: path);
        expect(_at(path).isLayeredLibrary, isFalse, reason: path);
      }
    });

    test('host and target ownership', () {
      final windows = _at('lib/src/host/windows/adi/loader.dart');
      expect(windows.host, 'windows');
      expect(windows.target, sharedAxis);
      expect(windows.isImplementation, isTrue);

      final posix = _at('lib/host/shared/posix.dart');
      expect(posix.host, sharedAxis);
      expect(posix.concreteHost, isFalse);

      final iphone = _at('lib/target/iphone/device/pymd.dart');
      expect(iphone.target, 'iphone');
      expect(iphone.host, sharedAxis);

      final nested = _at('lib/src/host/macos/target/simulator/bridge.dart');
      expect(nested.host, 'macos');
      expect(nested.target, 'simulator');
    });

    test('a shared directory named like an axis is not an axis', () {
      final location = _at('lib/src/shared/host/device_policy.dart');
      expect(location.layer, 'shared');
      expect(location.host, sharedAxis);
      expect(location.hasKnownLayer, isTrue);
    });

    test('layout violations', () {
      expect(_at('lib/src/legacy/policy.dart').hasKnownLayer, isFalse);
      expect(_at('lib/policy.dart').hasKnownLayer, isFalse);
      expect(_at('lib/src/host/policy.dart').hasKnownLayer, isFalse);
      expect(_at('lib/src/target/policy.dart').hasKnownLayer, isFalse);
    });

    test('package URIs map to lib', () {
      final location = SourceLocation.ofPackageUri(
        Uri.parse('package:pkg/src/host/linux/linux_host.dart'),
      );
      expect(location.zone, Zone.library);
      expect(location.host, 'linux');
    });

    test('generated files', () {
      expect(_at('lib/src/shared/version.g.dart').isGenerated, isTrue);
    });

    test('paths without a package root anchor on the first zone', () {
      final location = SourceLocation.of(
        '/w/packages/pkg/lib/src/shared/test/helpers.dart',
      );
      expect(location.zone, Zone.library);
      expect(location.layer, 'shared');
    });
  });
}
