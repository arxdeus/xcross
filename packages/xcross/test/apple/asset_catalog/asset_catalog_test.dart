import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog_reader.dart';

import '../support/native_test_file_system.dart';

void main() {
  late Directory tmp;
  late String xc;
  final paths = p.context;
  const fs = NativeTestFileSystem();

  void write(String rel, Object content) {
    final f = File(p.join(xc, rel))..parent.createSync(recursive: true);
    if (content is List<int>) {
      f.writeAsBytesSync(content);
    } else {
      f.writeAsStringSync(content as String);
    }
  }

  List<int> png(int size, {bool alpha = false}) {
    final image = img.Image(
      width: size,
      height: size,
      numChannels: alpha ? 4 : 3,
    );
    return img.encodePng(image);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xc_assets');
    xc = p.join(tmp.path, 'A.xcassets');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('reads image, color, namespaces, skips and bad sets', () {
    write(
      'a.imageset/Contents.json',
      jsonEncode({
        'images': [
          {'filename': 'a.png', 'scale': '2x', 'idiom': 'universal'},
          {'filename': 'gone.png', 'scale': '3x'},
          {'scale': '1x'},
          {
            'filename': 'a.png',
            'scale': '1x',
            'appearances': [
              {'appearance': 'luminosity', 'value': 'dark'},
            ],
          },
        ],
      }),
    );
    write('a.imageset/a.png', png(2));
    write('NS/Contents.json', '{"properties":{"provides-namespace":true}}');
    write(
      'NS/b.colorset/Contents.json',
      jsonEncode({
        'colors': [
          {
            'color': {
              'color-space': 'srgb',
              'components': {
                'red': '0x33',
                'green': '51',
                'blue': '0.200',
                'alpha': '1.000',
              },
            },
          },
          {
            'appearances': [
              {'appearance': 'luminosity', 'value': 'dark'},
            ],
            'color': {
              'color-space': 'gray-gamma-22',
              'components': {'white': '0.5', 'alpha': '1'},
            },
          },
        ],
      }),
    );
    write('plain/c.colorset/Contents.json', '{"colors":[]}');
    write('s.symbolset/Contents.json', '{}');
    write('bad.imageset/Contents.json', '{nope');
    // Windows editors may save Contents.json with a UTF-8 BOM and CRLF.
    write('bom.colorset/Contents.json', '\uFEFF{"colors":[]}\r\n');

    final r = AssetCatalogReader(fs, paths).read(xc);
    expect(r.skipped, ['s.symbolset']);
    expect(r.diagnostics, hasLength(1));
    final a = r.catalog.imageSet('a')!;
    expect(a.images.map((e) => e.scale), [2, 1]);
    expect(a.images.last.appearance, AssetAppearance.dark);
    expect(r.catalog.imageSet('bad'), isNull);
    expect(r.catalog.colorSets.map((c) => c.name), contains('bom'));
    final b = r.catalog.colorSet('NS/b')!;
    expect(b.colors.first.color.red, closeTo(0.2, 1e-9));
    expect(b.colors.first.color.green, closeTo(0.2, 1e-9));
    expect(b.colors.first.color.blue, 0.2);
    expect(b.colors.last.color, const AssetColor.gray(0.5));
    expect(r.catalog.colorSet('c'), isNotNull);
  });
}
