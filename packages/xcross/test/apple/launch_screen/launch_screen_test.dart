import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_screen_plan.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_screen_plist.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_storyboard_locator.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_storyboard_reader.dart';

import '../support/native_test_file_system.dart';

String _sb(String view, {String resources = ''}) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<document initialViewController="VC">
<scenes><scene sceneID="s"><objects>
<viewController id="VC"><view key="view" id="V">$view</view></viewController>
</objects></scene></scenes>
<resources>$resources</resources>
</document>''';

const _flutter = '''
<subviews><imageView contentMode="center" image="LaunchImage" id="IV"/></subviews>
<color key="backgroundColor" red="1" green="1" blue="1" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>
<constraints>
<constraint firstItem="IV" firstAttribute="centerX" secondItem="V" secondAttribute="centerX" id="a"/>
<constraint firstItem="IV" firstAttribute="centerY" secondItem="V" secondAttribute="centerY" id="b"/>
</constraints>''';

const _splash = '''
<subviews>
<imageView contentMode="scaleToFill" image="LaunchBackground" id="BG"/>
<imageView contentMode="center" image="LaunchImage" id="IV"/></subviews>
<constraints>
<constraint firstItem="BG" firstAttribute="top" secondItem="V" secondAttribute="top" id="1"/>
<constraint firstItem="BG" firstAttribute="bottom" secondItem="V" secondAttribute="bottom" id="2"/>
<constraint firstItem="BG" firstAttribute="leading" secondItem="V" secondAttribute="leading" id="3"/>
<constraint firstItem="BG" firstAttribute="trailing" secondItem="V" secondAttribute="trailing" id="4"/>
<constraint firstItem="IV" firstAttribute="centerX" secondItem="V" secondAttribute="centerX" id="a"/>
<constraint firstItem="IV" firstAttribute="centerY" secondItem="V" secondAttribute="centerY" id="b"/>
</constraints>''';

void main() {
  test('flutter default template', () {
    final s = LaunchStoryboardReader.read(_sb(_flutter))!;
    expect(s.imageName, 'LaunchImage');
    expect(s.imageIsCentered, isTrue);
    expect(s.backgroundColor, const AssetColor(red: 1, green: 1, blue: 1));
    expect(s.unsupported, isEmpty);
  });

  test('system color and named color', () {
    final sys = LaunchStoryboardReader.read(
      _sb(
        '<color key="backgroundColor" systemColor="systemBackgroundColor"/>',
        resources:
            '<systemColor name="systemBackgroundColor"><color white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/></systemColor>',
      ),
    )!;
    expect(sys.backgroundColor, const AssetColor.gray(1));
    final named = LaunchStoryboardReader.read(
      _sb('<color key="backgroundColor" name="LaunchBackground"/>'),
    )!;
    expect(named.backgroundColorName, 'LaunchBackground');
  });

  test('unsupported elements reported', () {
    final s = LaunchStoryboardReader.read(
      _sb(
        '<subviews><label text="Hi" id="L"/> '
        '<imageView contentMode="scaleAspectFill" image="X" id="I"/></subviews>',
      ),
    )!;
    expect(s.unsupported, hasLength(2));
    expect(LaunchStoryboardReader.read('nope'), isNull);
  });

  group('planner', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ls_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('synthesizes color and keeps present image', () {
      final spec = LaunchStoryboardReader.read(_sb(_flutter))!;
      final plan = const LaunchScreenPlanner().plan(
        spec,
        const AssetCatalog(
          path: 'x',
          imageSets: [ImageSetAsset(name: 'LaunchImage', images: [])],
        ),
      );
      expect(plan.uiLaunchScreen, {
        'UIColorName': 'XCrossLaunchBackground',
        'UIImageName': 'LaunchImage',
      });
      expect(plan.synthesizedColor, isNotNull);
    });

    test('missing image warns', () {
      final spec = LaunchStoryboardReader.read(_sb(_flutter))!;
      final plan = const LaunchScreenPlanner().plan(
        spec,
        const AssetCatalog(path: 'x'),
      );
      expect(plan.uiLaunchScreen.containsKey('UIImageName'), isFalse);
      expect(plan.warnings, isNotEmpty);
    });

    test('flutter_native_splash solid background image', () {
      final png = p.join(tmp.path, 'bg.png');
      final image = img.Image(width: 1, height: 1)
        ..setPixelRgba(0, 0, 255, 0, 0, 255);
      File(png).writeAsBytesSync(img.encodePng(image));
      final spec = LaunchStoryboardReader.read(_sb(_splash))!;
      expect(spec.backgroundImageName, 'LaunchBackground');
      final plan = const LaunchScreenPlanner(fileSystem: NativeTestFileSystem())
          .plan(
            spec,
            AssetCatalog(
              path: 'x',
              imageSets: [
                ImageSetAsset(
                  name: 'LaunchBackground',
                  images: [ImageSetEntry(filePath: png)],
                ),
                const ImageSetAsset(name: 'LaunchImage', images: []),
              ],
            ),
          );
      final c = plan.synthesizedColor!.colors.single.color;
      expect([c.red, c.green, c.blue], [1, 0, 0]);
    });
  });

  group('plist', () {
    const ui = {'UIColorName': 'C', 'UIImageName': 'I'};
    test('replaces key', () {
      const xml =
          '<dict>\n\t<key>UILaunchStoryboardName</key>\n\t<string>LaunchScreen</string>\n</dict>';
      final out = LaunchScreenPlist.apply(xml, ui);
      expect(out, contains('<key>UILaunchScreen</key>'));
      expect(out, contains('<string>I</string>'));
      expect(out, isNot(contains('UILaunchStoryboardName')));
    });
    test('ipad variant and existing UILaunchScreen', () {
      const xml =
          '<dict><key>UILaunchStoryboardName~ipad</key><string>L</string></dict>';
      expect(LaunchScreenPlist.apply(xml, ui), contains('UILaunchScreen'));
      final dup = LaunchScreenPlist.apply(
        '<key>UILaunchScreen</key><dict/>$xml',
        ui,
      );
      expect(dup, isNot(contains('UILaunchStoryboardName')));
      expect('UILaunchScreen'.allMatches(dup), hasLength(1));
    });
  });

  test('locator prefers Base.lproj', () {
    final tmp = Directory.systemTemp.createTempSync('loc_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    for (final d in ['Base.lproj', 'en.lproj']) {
      Directory(
        p.join(tmp.path, 'ios', 'Runner', d),
      ).createSync(recursive: true);
      File(
        p.join(tmp.path, 'ios', 'Runner', d, 'LaunchScreen.storyboard'),
      ).writeAsStringSync('');
    }
    final found = LaunchStoryboardLocator(
      const NativeTestFileSystem(),
      p.context,
    ).locate(tmp.path, 'LaunchScreen');
    expect(found, contains('Base.lproj'));
    expect(
      LaunchStoryboardLocator(
        const NativeTestFileSystem(),
        p.context,
      ).locate(tmp.path, 'Nope'),
      isNull,
    );
  });
}
