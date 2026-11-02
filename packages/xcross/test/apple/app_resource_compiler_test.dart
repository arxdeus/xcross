import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/app_resource_compiler.dart';

import '../flutter/flutter_test_log.dart';
import '../flutter/flutter_test_runtime.dart';

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
  final fs = testIPhoneRuntime().host.fileSystem;

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
    expect(xml, isNot(contains('UILaunchStoryboardName')));
    expect(xml, contains('<key>UILaunchScreen</key>'));
    expect(xml, contains('<key>UIImageName</key>'));
    expect(xml, contains('<string>LaunchImage</string>'));
    expect(xml, contains('<string>XCrossLaunchBackground</string>'));
    final car = File(p.join(bundle.path, 'Assets.car'));
    expect(car.existsSync(), isTrue);
    expect(ascii.decode(car.readAsBytesSync().sublist(0, 8)), 'BOMStore');
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
}
