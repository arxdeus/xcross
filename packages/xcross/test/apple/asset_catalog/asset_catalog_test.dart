import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/asset_catalog/app_icon_stager.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog_reader.dart';

import '../../flutter/flutter_test_runtime.dart';

void main() {
  late Directory tmp;
  late String xc;
  final paths = p.context;
  final fs = testIPhoneRuntime().host.fileSystem;

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

    final r = AssetCatalogReader(fs, paths).read(xc);
    expect(r.skipped, ['s.symbolset']);
    expect(r.diagnostics, hasLength(1));
    final a = r.catalog.imageSet('a')!;
    expect(a.images.map((e) => e.scale), [2, 1]);
    expect(a.images.last.appearance, AssetAppearance.dark);
    expect(r.catalog.imageSet('bad'), isNull);
    final b = r.catalog.colorSet('NS/b')!;
    expect(b.colors.first.color.red, closeTo(0.2, 1e-9));
    expect(b.colors.first.color.green, closeTo(0.2, 1e-9));
    expect(b.colors.first.color.blue, 0.2);
    expect(b.colors.last.color, const AssetColor.gray(0.5));
    expect(r.catalog.colorSet('c'), isNotNull);
  });

  test('stages legacy icons loose and patches Info.plist', () async {
    write(
      'AppIcon.appiconset/Contents.json',
      jsonEncode({
        'images': [
          {
            'size': '60x60',
            'idiom': 'iphone',
            'filename': 'a.png',
            'scale': '2x',
          },
          {
            'size': '60x60',
            'idiom': 'iphone',
            'filename': 'a.png',
            'scale': '3x',
          },
          {
            'size': '83.5x83.5',
            'idiom': 'ipad',
            'filename': 'a.png',
            'scale': '2x',
          },
          {
            'size': '1024x1024',
            'idiom': 'ios-marketing',
            'filename': 'a.png',
            'scale': '1x',
          },
        ],
      }),
    );
    write('AppIcon.appiconset/a.png', png(8));
    final cat = AssetCatalogReader(fs, paths).read(xc).catalog;
    final app = p.join(tmp.path, 'Runner.app');
    Directory(app).createSync();
    final plist = await AppIconStager(fs, paths).stage(
      cat.appIconSet('AppIcon')!,
      bundleDir: app,
      deviceFamilies: {AssetIdiom.iphone, AssetIdiom.ipad},
    );
    expect(File(p.join(app, 'AppIcon60x60@2x.png')).existsSync(), isTrue);
    expect(File(p.join(app, 'AppIcon60x60@3x.png')).existsSync(), isTrue);
    expect(
      File(p.join(app, 'AppIcon83.5x83.5@2x~ipad.png')).existsSync(),
      isTrue,
    );
    expect(plist.cfBundleIconsIpad, isNotNull);
    final xml = AppIconPlist.applyToInfoPlist(
      '<plist>\n<dict>\n\t<key>CFBundleIcons</key>\n\t<dict/>\n</dict>\n</plist>',
      plist,
    );
    expect('CFBundleIcons</key>'.allMatches(xml), hasLength(1));
    expect(xml, contains('<string>AppIcon83.5x83.5</string>'));
    expect(xml, contains('<key>CFBundleIconName</key>'));
  });

  test('synthesizes sizes from single 1024 icon, opaque', () async {
    write(
      'AppIcon.appiconset/Contents.json',
      jsonEncode({
        'images': [
          {
            'size': '1024x1024',
            'idiom': 'universal',
            'platform': 'ios',
            'filename': 'big.png',
          },
        ],
      }),
    );
    write('AppIcon.appiconset/big.png', png(256, alpha: true));
    final cat = AssetCatalogReader(fs, paths).read(xc).catalog;
    final app = p.join(tmp.path, 'Runner.app');
    Directory(app).createSync();
    await AppIconStager(fs, paths).stage(
      cat.appIconSet('AppIcon')!,
      bundleDir: app,
      deviceFamilies: {AssetIdiom.iphone, AssetIdiom.ipad},
    );
    final sizes = {
      'AppIcon60x60@2x.png': 120,
      'AppIcon60x60@3x.png': 180,
      'AppIcon76x76@2x~ipad.png': 152,
      'AppIcon83.5x83.5@2x~ipad.png': 167,
    };
    sizes.forEach((name, px) {
      final d = img.decodePng(File(p.join(app, name)).readAsBytesSync())!;
      expect(d.width, px);
      expect(d.hasAlpha, isFalse);
    });
  });
}
