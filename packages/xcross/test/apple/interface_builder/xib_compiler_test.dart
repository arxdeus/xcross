import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_color_transform.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_compiler.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_float32.dart';
import 'package:xcross/src/shared/apple/interface_builder/xib_key_table_order.dart';

final String _fixtures = p.join(
  'test',
  'apple',
  'interface_builder',
  'fixtures',
);

String _readXib(String name) =>
    utf8.decode(File(p.join(_fixtures, name)).readAsBytesSync());

XibCompilation _compileFixture(String name) => const XibCompiler().compile(
  _readXib(name),
  module: 'google_mobile_ads',
  deploymentTarget: '13.0',
);

void main() {
  group('byte identical to ibtool', () {
    final names =
        Directory(_fixtures)
            .listSync()
            .map((e) => p.basename(e.path))
            .where((n) => n.endsWith('.xib'))
            .toList()
          ..sort();
    for (final xib in names) {
      test(xib, () {
        final result = _compileFixture(xib);
        expect(result.unsupported, isEmpty);
        final expected = File(
          p.join(_fixtures, xib.replaceAll('.xib', '.nib')),
        ).readAsBytesSync();
        expect(result.nib, orderedEquals(expected));
      });
    }
  });

  test('Generic RGB to sRGB matches ColorSync bit for bit', () {
    final lines = File(
      p.join(_fixtures, 'generic_rgb_colors.txt'),
    ).readAsLinesSync().where((l) => l.isNotEmpty);
    for (final line in lines) {
      final v = line.split(' ').map(double.parse).toList();
      final c = XibColorTransform.genericRgbToSrgb(v[0], v[1], v[2]);
      expect(
        [f32(c[0]), f32(c[1]), f32(c[2])],
        [v[3], v[4], v[5]],
        reason: line,
      );
    }
  });

  test('CFString hash', () {
    expect(XibKeyTableOrder.cfHash('a'), BigInt.from(1062));
    expect(XibKeyTableOrder.cfHash('ab'), BigInt.from(785625));
    expect(
      XibKeyTableOrder.cfHash('UIBounds'),
      BigInt.parse('16036535914978476561'),
    );
  });

  group('unsupported input is reported, never miscompiled', () {
    XibCompilation compileObjects(String objects) =>
        const XibCompiler().compile(
          _readXib('GADTSmallTemplateView.xib').replaceFirst(
            '<placeholder placeholderIdentifier="IBFirstResponder"',
            '$objects<placeholder placeholderIdentifier="IBFirstResponder"',
          ),
          module: 'm',
          deploymentTarget: '13.0',
        );

    test('unknown element', () {
      final r = compileObjects(
        '<tableView id="t1"><rect key="frame" x="0" y="0" width="1" height="1"/></tableView>',
      );
      expect(r.nib, isNull);
      expect(r.unsupported.single, contains('tableView'));
    });

    test('unknown attribute', () {
      final r = compileObjects(
        '<view contentMode="scaleToFill" semanticContentAttribute="forceRightToLeft" id="v9"><rect key="frame" x="0" y="0" width="1" height="1"/><autoresizingMask key="autoresizingMask"/></view>',
      );
      expect(r.unsupported.single, contains('semanticContentAttribute'));
    });

    test('unknown color space', () {
      final r = compileObjects(
        '<view contentMode="scaleToFill" id="v9"><rect key="frame" x="0" y="0" width="1" height="1"/><autoresizingMask key="autoresizingMask"/><color key="backgroundColor" red="1" green="0" blue="0" alpha="1" colorSpace="custom" customColorSpace="adobeRGB1998"/></view>',
      );
      expect(r.unsupported.single, contains('adobeRGB1998'));
    });

    test('malformed xml', () {
      final r = const XibCompiler().compile(
        '<document',
        module: 'm',
        deploymentTarget: '13.0',
      );
      expect(r.unsupported, isNotEmpty);
    });
  });
}
