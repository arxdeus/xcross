import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/asset_catalog/app_icon_stager.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog_reader.dart';

import '../support/native_test_file_system.dart';

/// Expectations recorded from `xcrun actool` (Xcode 26.6) with the same
/// catalogs: `--platform iphoneos --app-icon AppIcon
/// --minimum-deployment-target T --target-device ...`.
void main() {
  late Directory tmp;
  late String xc;
  late String app;
  const fs = NativeTestFileSystem();
  final paths = p.context;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('icon_golden');
    xc = p.join(tmp.path, 'Assets.xcassets');
    app = p.join(tmp.path, 'Runner.app');
    Directory(app).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String rel, Object content) {
    final f = File(p.join(xc, rel))..parent.createSync(recursive: true);
    content is List<int>
        ? f.writeAsBytesSync(content)
        : f.writeAsStringSync(content as String);
  }

  List<int> png(int px, {int seed = 0}) => img.encodePng(
    img.Image(width: px, height: px)..setPixelRgb(0, 0, seed, px % 256, 7),
  );

  /// The Flutter template's legacy set: one file per slot.
  void legacySet(String name) {
    const slots = [
      ('20x20', 'iphone', 2), ('20x20', 'iphone', 3), //
      ('29x29', 'iphone', 1), ('29x29', 'iphone', 2), ('29x29', 'iphone', 3),
      ('40x40', 'iphone', 2), ('40x40', 'iphone', 3),
      ('60x60', 'iphone', 2), ('60x60', 'iphone', 3),
      ('20x20', 'ipad', 1), ('20x20', 'ipad', 2),
      ('29x29', 'ipad', 1), ('29x29', 'ipad', 2),
      ('40x40', 'ipad', 1), ('40x40', 'ipad', 2),
      ('76x76', 'ipad', 1), ('76x76', 'ipad', 2),
      ('83.5x83.5', 'ipad', 2), ('1024x1024', 'ios-marketing', 1),
    ];
    final images = <Map<String, String>>[];
    for (final (i, (size, idiom, scale)) in slots.indexed) {
      final file = 'Icon-$idiom-$size@${scale}x.png';
      final px = (double.parse(size.split('x').first) * scale).round();
      write('$name.appiconset/$file', png(px, seed: i));
      images.add({
        'size': size,
        'idiom': idiom,
        'filename': file,
        'scale': '${scale}x',
      });
    }
    write('$name.appiconset/Contents.json', jsonEncode({'images': images}));
  }

  void singleSet(String name) {
    final image = img.Image(width: 1024, height: 1024, numChannels: 4);
    write('$name.appiconset/icon.png', img.encodePng(image));
    write(
      '$name.appiconset/Contents.json',
      jsonEncode({
        'images': [
          {
            'filename': 'icon.png',
            'idiom': 'universal',
            'platform': 'ios',
            'size': '1024x1024',
          },
        ],
      }),
    );
  }

  Future<AppIconPlist> stage(
    Set<AssetIdiom> devices,
    String target, {
    List<String> alternates = const [],
  }) {
    final cat = AssetCatalogReader(fs, paths).read(xc).catalog;
    return AppIconStager(fs, paths).stage(
      cat.appIconSet('AppIcon')!,
      bundleDir: app,
      deviceFamilies: devices,
      deploymentTarget: target,
      alternates: [for (final a in alternates) cat.appIconSet(a)!],
    );
  }

  List<String> loose() =>
      Directory(app).listSync().map((e) => p.basename(e.path)).toList()..sort();

  Map<String, Object?> primary(List<String> files, {bool named = true}) => {
    'CFBundlePrimaryIcon': {
      'CFBundleIconFiles': files,
      'CFBundleIconName': ?(named ? 'AppIcon' : null),
    },
  };

  const both = {AssetIdiom.iphone, AssetIdiom.ipad};

  test('legacy set, iOS 13, iPhone and iPad', () async {
    legacySet('AppIcon');
    final plist = await stage(both, '13.0');
    expect(loose(), ['AppIcon60x60@2x.png', 'AppIcon76x76@2x~ipad.png']);
    expect(plist.cfBundleIcons, primary(['AppIcon60x60']));
    expect(plist.cfBundleIconsIpad, primary(['AppIcon60x60', 'AppIcon76x76']));
    // Byte for byte copies of the source slots.
    expect(
      File(p.join(app, 'AppIcon60x60@2x.png')).readAsBytesSync(),
      File(
        p.join(xc, 'AppIcon.appiconset', 'Icon-iphone-60x60@2x.png'),
      ).readAsBytesSync(),
    );
  });

  test('legacy set, iOS 13, iPhone only still writes the iPad icon', () async {
    legacySet('AppIcon');
    final plist = await stage({AssetIdiom.iphone}, '15.0');
    expect(loose(), ['AppIcon60x60@2x.png', 'AppIcon76x76@2x~ipad.png']);
    expect(plist.cfBundleIconsIpad, primary(['AppIcon60x60', 'AppIcon76x76']));
  });

  test('legacy set, iOS 10.3: every slot loose', () async {
    legacySet('AppIcon');
    final plist = await stage(both, '10.3');
    expect(loose(), [
      'AppIcon20x20@2x.png', 'AppIcon20x20@2x~ipad.png', //
      'AppIcon20x20@3x.png', 'AppIcon20x20~ipad.png',
      'AppIcon29x29.png', 'AppIcon29x29@2x.png', 'AppIcon29x29@2x~ipad.png',
      'AppIcon29x29@3x.png', 'AppIcon29x29~ipad.png',
      'AppIcon40x40@2x.png', 'AppIcon40x40@2x~ipad.png',
      'AppIcon40x40@3x.png', 'AppIcon40x40~ipad.png',
      'AppIcon60x60@2x.png', 'AppIcon60x60@3x.png',
      'AppIcon76x76@2x~ipad.png', 'AppIcon76x76~ipad.png',
      'AppIcon83.5x83.5@2x~ipad.png',
    ]);
    const phone = ['AppIcon20x20', 'AppIcon29x29', 'AppIcon40x40'];
    expect(plist.cfBundleIcons, primary([...phone, 'AppIcon60x60']));
    expect(
      plist.cfBundleIconsIpad,
      primary([...phone, 'AppIcon60x60', 'AppIcon76x76', 'AppIcon83.5x83.5']),
    );
  });

  test('single size, iOS 13, iPhone only: no iPad icon name', () async {
    singleSet('AppIcon');
    final plist = await stage({AssetIdiom.iphone}, '13.0');
    expect(loose(), ['AppIcon60x60@2x.png', 'AppIcon76x76@2x~ipad.png']);
    expect(plist.cfBundleIcons, primary(['AppIcon60x60']));
    expect(
      plist.cfBundleIconsIpad,
      primary(['AppIcon60x60', 'AppIcon76x76'], named: false),
    );
    for (final (name, px) in [
      ('AppIcon60x60@2x.png', 120),
      ('AppIcon76x76@2x~ipad.png', 152),
    ]) {
      final d = img.decodePng(File(p.join(app, name)).readAsBytesSync())!;
      expect(d.width, px);
      expect(d.numChannels, 4, reason: 'actool writes RGBA, unflattened');
    }
  });

  test('single size, iOS 10.3, iPhone and iPad', () async {
    singleSet('AppIcon');
    final plist = await stage(both, '10.3');
    expect(loose(), [
      'AppIcon1024x1024.png', 'AppIcon20x20@2x.png', //
      'AppIcon20x20@2x~ipad.png', 'AppIcon20x20@3x.png',
      'AppIcon29x29@2x.png', 'AppIcon29x29@2x~ipad.png', 'AppIcon29x29@3x.png',
      'AppIcon40x40@2x.png', 'AppIcon40x40@2x~ipad.png', 'AppIcon40x40@3x.png',
      'AppIcon60x60@2x.png', 'AppIcon60x60@3x.png',
      'AppIcon76x76@2x~ipad.png', 'AppIcon83.5x83.5@2x~ipad.png',
    ]);
    const shared = ['AppIcon1024x1024', 'AppIcon20x20', 'AppIcon29x29'];
    expect(
      plist.cfBundleIcons,
      primary([...shared, 'AppIcon40x40', 'AppIcon60x60']),
    );
    expect(
      plist.cfBundleIconsIpad,
      primary([...shared, 'AppIcon40x40', 'AppIcon76x76', 'AppIcon83.5x83.5']),
    );
  });

  test('alternate icons, iOS 15, iPhone and iPad', () async {
    singleSet('AppIcon');
    singleSet('AppIconRed');
    final plist = await stage(both, '15.0', alternates: ['AppIconRed']);
    expect(loose(), ['AppIcon60x60@2x.png', 'AppIcon76x76@2x~ipad.png']);
    const alternates = {
      'AppIconRed': {'CFBundleIconName': 'AppIconRed'},
    };
    expect(plist.cfBundleIcons, {
      'CFBundleAlternateIcons': alternates,
      ...primary(['AppIcon60x60']),
    });
    expect(plist.cfBundleIconsIpad, {
      'CFBundleAlternateIcons': alternates,
      ...primary(['AppIcon60x60', 'AppIcon76x76']),
    });
  });

  test('alternate icons, iOS 15, iPhone only', () async {
    singleSet('AppIcon');
    singleSet('AppIconRed');
    final plist = await stage(
      {AssetIdiom.iphone},
      '15.0',
      alternates: ['AppIconRed'],
    );
    expect(plist.cfBundleIcons['CFBundleAlternateIcons'], isNotNull);
    expect(
      plist.cfBundleIconsIpad,
      primary(['AppIcon60x60', 'AppIcon76x76'], named: false),
    );
  });

  test('XML fragment is a single top-level CFBundleIcons pair', () async {
    legacySet('AppIcon');
    final plist = await stage(both, '13.0');
    final xml = AppIconPlist.applyToInfoPlist(
      '<plist>\n<dict>\n\t<key>CFBundleIcons</key>\n\t<dict/>\n</dict>\n'
      '</plist>',
      plist,
    );
    expect('<key>CFBundleIcons</key>'.allMatches(xml), hasLength(1));
    expect('<key>CFBundleIcons~ipad</key>'.allMatches(xml), hasLength(1));
  });
}
