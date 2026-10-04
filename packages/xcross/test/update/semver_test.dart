import 'package:test/test.dart';
import 'package:xcross/src/shared/update/semver.dart';

XcrossSemver _parse(String value) {
  final parsed = XcrossSemver.tryParse(value);
  expect(parsed, isNotNull, reason: 'expected $value to parse');
  return parsed!;
}

void main() {
  group('XcrossSemver.tryParse', () {
    test('accepts bare and v-prefixed tags alike', () {
      expect(_parse('1.2.3').toString(), '1.2.3');
      expect(_parse('v1.2.3').toString(), '1.2.3');
      expect(_parse('  1.2.3  ').toString(), '1.2.3');
    });

    test('keeps the pre-release and drops build metadata', () {
      expect(_parse('1.0.0-dev').preRelease, 'dev');
      expect(_parse('1.0.0-dev').isPreRelease, isTrue);
      expect(_parse('1.2.3+abc123').preRelease, isNull);
      expect(_parse('1.2.3').isPreRelease, isFalse);
    });

    test('rejects anything that is not a release version', () {
      for (final bad in [
        '',
        'latest',
        '1.2',
        '1.2.3.4',
        'v',
        'x1.2.3',
        '1.2.3-',
        '01.2.3-\u00e9',
      ]) {
        expect(
          XcrossSemver.tryParse(bad),
          isNull,
          reason: 'expected $bad to be rejected',
        );
      }
    });
  });

  group('ordering', () {
    test('compares numeric fields left to right', () {
      expect(_parse('2.0.0').isNewerThan(_parse('1.9.9')), isTrue);
      expect(_parse('1.3.0').isNewerThan(_parse('1.2.9')), isTrue);
      expect(_parse('1.2.10').isNewerThan(_parse('1.2.9')), isTrue);
      expect(_parse('1.2.3').isNewerThan(_parse('1.2.3')), isFalse);
      expect(_parse('1.2.3').isNewerThan(_parse('1.2.4')), isFalse);
    });

    test('a pre-release sorts below the release it leads up to', () {
      expect(_parse('1.3.0').isNewerThan(_parse('1.3.0-dev')), isTrue);
      expect(_parse('1.3.0-dev').isNewerThan(_parse('1.3.0')), isFalse);
      expect(_parse('1.3.0-dev').isNewerThan(_parse('1.2.9')), isTrue);
    });

    test('a released build is newer than the dev build it came from', () {
      expect(_parse('1.0.0').isNewerThan(_parse('1.0.0-dev')), isTrue);
    });

    test('sorts a mixed list', () {
      final versions = [
        _parse('1.3.0'),
        _parse('1.0.0-dev'),
        _parse('1.2.10'),
        _parse('1.0.0'),
        _parse('1.3.0-dev'),
      ]..sort();
      expect(versions.map((v) => v.toString()), [
        '1.0.0-dev',
        '1.0.0',
        '1.2.10',
        '1.3.0-dev',
        '1.3.0',
      ]);
    });

    test('equality ignores the leading v', () {
      expect(_parse('v1.2.3'), _parse('1.2.3'));
      expect(_parse('v1.2.3').hashCode, _parse('1.2.3').hashCode);
      expect(_parse('1.2.3-dev'), isNot(_parse('1.2.3')));
    });
  });
}
