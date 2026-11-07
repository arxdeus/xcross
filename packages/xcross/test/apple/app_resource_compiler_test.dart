import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/app_resource_compiler.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/asset_catalog/assets_car_writer.dart';

import '../flutter/flutter_test_log.dart';
import 'support/native_test_file_system.dart';

const _storyboard = '''
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document initialViewController="01J-lp-oVM">
<scenes><scene sceneID="EHf-IW-A2E"><objects>
<viewController id="01J-lp-oVM">
<view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">
<subviews>
<imageView contentMode="center" image="LaunchImage" id="YRO-k0-Ey4"/>
</subviews>
<color key="backgroundColor" red="1" green="1" blue="1" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>
<constraints>
<constraint firstItem="YRO-k0-Ey4" firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" id="1a2-6s-vTC"/>
<constraint firstItem="YRO-k0-Ey4" firstAttribute="centerY" secondItem="Ze5-6b-2t3" secondAttribute="centerY" id="4X2-HB-R7a"/>
</constraints>
</view>
</viewController>
</objects></scene></scenes>
<resources><image name="LaunchImage" width="168" height="185"/></resources>
</document>
''';

const _plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Runner</string>
	<key>UILaunchStoryboardName</key>
	<string>LaunchScreen</string>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
</dict>
</plist>
''';

void main() {
  late Directory tmp;
  const fs = NativeTestFileSystem();

  setUp(() => tmp = Directory.systemTemp.createTempSync('arc_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  AppResourceCompiler compiler() => AppResourceCompiler(
    fileSystem: fs,
    paths: p.context,
    log: testFlutterLog(),
  );

  void write(String rel, Object content) {
    final f = File(p.join(tmp.path, rel))..parent.createSync(recursive: true);
    if (content is List<int>) {
      f.writeAsBytesSync(content);
    } else {
      f.writeAsStringSync(content as String);
    }
  }

  List<int> png(int size) =>
      img.encodePng(img.Image(width: size, height: size));

  test('compiles icon, launch screen and Assets.car', () async {
    const cat = 'Assets.xcassets';
    write(
      p.join(cat, 'AppIcon.appiconset', 'Contents.json'),
      jsonEncode({
        'images': [
          for (final scale in ['2x', '3x'])
            {
              'size': '60x60',
              'idiom': 'iphone',
              'filename': 'icon$scale.png',
              'scale': scale,
            },
        ],
      }),
    );
    write(p.join(cat, 'AppIcon.appiconset', 'icon2x.png'), png(120));
    write(p.join(cat, 'AppIcon.appiconset', 'icon3x.png'), png(180));
    write(
      p.join(cat, 'LaunchImage.imageset', 'Contents.json'),
      jsonEncode({
        'images': [
          for (final scale in ['1x', '2x', '3x'])
            {'idiom': 'universal', 'filename': 'li$scale.png', 'scale': scale},
        ],
      }),
    );
    for (final (i, scale) in ['1x', '2x', '3x'].indexed) {
      write(
        p.join(cat, 'LaunchImage.imageset', 'li$scale.png'),
        png(10 * (i + 1)),
      );
    }
    write(p.join('Base.lproj', 'LaunchScreen.storyboard'), _storyboard);
    final bundle = Directory(p.join(tmp.path, 'Runner.app'))..createSync();

    final xml = await compiler().compile(
      bundleDir: bundle.path,
      infoPlistXml: _plist,
      catalogs: [p.join(tmp.path, cat)],
      deploymentTarget: '13.0',
      launchStoryboard: p.join(
        tmp.path,
        'Base.lproj',
        'LaunchScreen.storyboard',
      ),
      deviceFamilies: AppResourceCompiler.deviceFamiliesOf(_plist),
    );

    final icon = File(p.join(bundle.path, 'AppIcon60x60@2x.png'));
    expect(icon.existsSync(), isTrue);
    expect(img.decodePng(icon.readAsBytesSync())!.width, 120);
    expect(xml, contains('CFBundleIcons'));
    expect(xml, contains('CFBundleIcons~ipad'));
    // Like Xcode: the storyboard is compiled, and the plist keeps naming it.
    expect(xml, contains('<key>UILaunchStoryboardName</key>'));
    expect(xml, isNot(contains('UILaunchScreen</key>')));
    final storyboardc = p.join(
      bundle.path,
      'Base.lproj',
      'LaunchScreen.storyboardc',
    );
    expect(
      Directory(storyboardc).listSync().map((e) => p.basename(e.path)),
      unorderedEquals([
        'Info.plist',
        'UIViewController-01J-lp-oVM.nib',
        '01J-lp-oVM-view-Ze5-6b-2t3.nib',
      ]),
    );
    final car = File(p.join(bundle.path, 'Assets.car'));
    expect(car.existsSync(), isTrue);
    expect(ascii.decode(car.readAsBytesSync().sublist(0, 8)), 'BOMStore');
  });

  test('falls back to UILaunchScreen for a storyboard ibtool output '
      'cannot be reproduced for', () async {
    const cat = 'Assets.xcassets';
    write(
      p.join(cat, 'LaunchImage.imageset', 'Contents.json'),
      jsonEncode({
        'images': [
          {'idiom': 'universal', 'filename': 'li.png', 'scale': '1x'},
        ],
      }),
    );
    write(p.join(cat, 'LaunchImage.imageset', 'li.png'), png(10));
    write(
      p.join('Base.lproj', 'LaunchScreen.storyboard'),
      _storyboard.replaceFirst(
        '</subviews>',
        '<label text="Loading" id="lbl-1"/></subviews>',
      ),
    );
    final bundle = Directory(p.join(tmp.path, 'Runner.app'))..createSync();

    final xml = await compiler().compile(
      bundleDir: bundle.path,
      infoPlistXml: _plist,
      catalogs: [p.join(tmp.path, cat)],
      deploymentTarget: '13.0',
      launchStoryboard: p.join(
        tmp.path,
        'Base.lproj',
        'LaunchScreen.storyboard',
      ),
    );

    expect(xml, isNot(contains('UILaunchStoryboardName')));
    expect(xml, contains('<key>UILaunchScreen</key>'));
    expect(xml, contains('<string>LaunchImage</string>'));
    expect(xml, contains('<string>XCrossLaunchBackground</string>'));
    expect(Directory(p.join(bundle.path, 'Base.lproj')).existsSync(), isFalse);
  });

  test('no catalogs and no storyboard leaves plist untouched', () async {
    final bundle = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
    final xml = await compiler().compile(
      bundleDir: bundle.path,
      infoPlistXml: _plist,
      catalogs: const [],
      deploymentTarget: '13.0',
    );
    expect(xml, _plist);
    expect(File(p.join(bundle.path, 'Assets.car')).existsSync(), isFalse);
  });

  group('Assets.car cache', () {
    late CountingCarWriter writer;
    late String cache;
    late String bundle;
    const cat = 'Cached.xcassets';

    setUp(() {
      writer = CountingCarWriter();
      cache = p.join(tmp.path, 'build', 'xcross-asset-catalog');
      bundle = (Directory(p.join(tmp.path, 'Runner.app'))..createSync()).path;
      write(
        p.join(cat, 'Logo.imageset', 'Contents.json'),
        jsonEncode({
          'images': [
            {'idiom': 'universal', 'filename': 'logo.png', 'scale': '1x'},
          ],
        }),
      );
      write(p.join(cat, 'Logo.imageset', 'logo.png'), png(8));
    });

    Future<Uint8List> build({String deploymentTarget = '13.0'}) async {
      await AppResourceCompiler(
        fileSystem: fs,
        paths: p.context,
        log: testFlutterLog(),
        carWriter: writer,
      ).compile(
        bundleDir: bundle,
        infoPlistXml: _plist,
        catalogs: [p.join(tmp.path, cat)],
        deploymentTarget: deploymentTarget,
        carCacheDirectory: cache,
      );
      return File(p.join(bundle, 'Assets.car')).readAsBytesSync();
    }

    List<String> cached() => [
      for (final f in Directory(cache).listSync()) p.basename(f.path),
    ];

    test('reuses the car when nothing changed', () async {
      final first = await build();
      File(p.join(bundle, 'Assets.car')).deleteSync();
      final second = await build();
      expect(writer.calls, 1);
      expect(second, first);
      expect(cached(), hasLength(1));
    });

    test('recompiles when image bytes or options change', () async {
      await build();
      write(p.join(cat, 'Logo.imageset', 'logo.png'), png(9));
      await build();
      expect(writer.calls, 2);
      await build(deploymentTarget: '15.0');
      expect(writer.calls, 3);
      expect(cached(), hasLength(AppResourceCompiler.carCacheEntries));
      // Back to an input set still in the cache.
      await build(deploymentTarget: '15.0');
      expect(writer.calls, 3);
    });

    test('cache key ignores image paths that moved but not their bytes', () {
      String key(String path) => AppResourceCompiler.carCacheKey(
        AssetCatalog(
          path: '/c',
          imageSets: [
            ImageSetAsset(
              name: 'Logo',
              images: [ImageSetEntry(filePath: path)],
            ),
          ],
        ),
        deploymentTarget: '13.0',
        appIconName: null,
        alternateAppIconNames: const [],
        targetDevices: const {AssetIdiom.iphone},
        readFile: (_) => Uint8List.fromList([1, 2, 3]),
      );
      expect(key(p.join('a', 'logo.png')), key(p.join('b', 'logo.png')));
      expect(key(p.join('a', 'logo.png')), isNot(key(p.join('a', 'x.png'))));
    });
  });
}

/// An [AssetsCarWriter] that counts how often it compiles.
@internal
final class CountingCarWriter extends AssetsCarWriter {
  CountingCarWriter();

  int calls = 0;

  @override
  Uint8List write(
    AssetCatalog catalog, {
    required Uint8List Function(String path) readFile,
    required String deploymentTarget,
    String? appIconName,
    Iterable<String> alternateAppIconNames = const [],
    Set<AssetIdiom> targetDevices = const {AssetIdiom.iphone, AssetIdiom.ipad},
  }) {
    calls++;
    return super.write(
      catalog,
      readFile: readFile,
      deploymentTarget: deploymentTarget,
      appIconName: appIconName,
      alternateAppIconNames: alternateAppIconNames,
      targetDevices: targetDevices,
    );
  }
}
