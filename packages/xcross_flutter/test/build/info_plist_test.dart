import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross_flutter/src/build/info_plist.dart';
import 'package:xcross_flutter/src/constants.dart';

const _minimalPlist =
    '<?xml version="1.0"?>\n'
    '<plist version="1.0">\n'
    '<dict>\n'
    '</dict>\n'
    '</plist>\n';

void main() {
  group('expandVars', () {
    test(
      r'replaces $(KEY) and ${KEY} forms, leaving unknown keys untouched',
      () {
        final result = InfoPlist.expandVars(
          r'v=$(VER) n=${NAME} x=$(MISSING)',
          {'VER': '1.0', 'NAME': 'App'},
        );

        expect(result, r'v=1.0 n=App x=$(MISSING)');
      },
    );
  });

  group('parseXcconfig', () {
    test('parses KEY = VALUE lines, stripping comments, blanks, config '
        'suffixes, and only splitting on the first "="', () {
      const text = '''
FOO = plain_value
// a full-line comment
# another full-line comment

BAR[debug] = bracket_value
BAZ = a=b
''';

      final result = InfoPlist.parseXcconfig(text);

      expect(result, {
        'FOO': 'plain_value',
        'BAR': 'bracket_value',
        'BAZ': 'a=b',
      });
    });
  });

  group('applyIosRequiredKeys', () {
    test('inserts all mandatory keys with sensible defaults', () {
      final result = InfoPlist.applyIosRequiredKeys(
        _minimalPlist,
        bundleId: 'com.example.app',
      );

      expect(
        result,
        contains(
          '<key>CFBundleExecutable</key>\n'
          '\t<string>${PlistDefaults.executable}</string>',
        ),
      );
      expect(
        result,
        contains(
          '<key>CFBundleIdentifier</key>\n\t<string>com.example.app</string>',
        ),
      );
      expect(
        result,
        contains('<key>CFBundlePackageType</key>\n\t<string>APPL</string>'),
      );
      expect(
        result,
        contains(
          '<key>${IosDeploymentConstants.minimumOsVersionKey}</key>\n'
          '\t<string>${IosDeploymentConstants.minDeploymentTarget}</string>',
        ),
      );
      expect(result, contains('<key>LSRequiresIPhoneOS</key>'));
      expect(result, contains('<key>CFBundleSupportedPlatforms</key>'));
      expect(result, contains('<key>UIRequiredDeviceCapabilities</key>'));
      expect(result, contains('<key>UIDeviceFamily</key>'));
      expect(result, contains('<key>DTPlatformName</key>'));
      expect(result, contains('<key>DTSDKName</key>'));
      expect(result, contains('<key>DTPlatformVersion</key>'));
    });

    test('does not overwrite an existing MinimumOSVersion value', () {
      const plist =
          '<?xml version="1.0"?>\n'
          '<plist version="1.0">\n'
          '<dict>\n'
          '\t<key>MinimumOSVersion</key>\n'
          '\t<string>15.5</string>\n'
          '</dict>\n'
          '</plist>\n';

      final result = InfoPlist.applyIosRequiredKeys(
        plist,
        bundleId: 'com.example.app',
      );

      expect(
        result,
        contains('<key>MinimumOSVersion</key>\n\t<string>15.5</string>'),
      );
      expect('<key>MinimumOSVersion</key>'.allMatches(result).length, 1);
    });

    // Regression check: this runs on every build, so without the presence
    // guards in `_ensureKey` a rebuild would pile up duplicate <key> pairs.
    test('applying twice does not duplicate ensure-only keys', () {
      final once = InfoPlist.applyIosRequiredKeys(
        _minimalPlist,
        bundleId: 'com.example.app',
      );
      final twice = InfoPlist.applyIosRequiredKeys(
        once,
        bundleId: 'com.example.app',
      );

      expect('<key>UIDeviceFamily</key>'.allMatches(twice).length, 1);
      expect('<key>LSRequiresIPhoneOS</key>'.allMatches(twice).length, 1);
      expect('<key>DTPlatformVersion</key>'.allMatches(twice).length, 1);
      expect('<key>CFBundleExecutable</key>'.allMatches(twice).length, 1);
    });
  });

  group('normalizeObjCClassNames', () {
    test('strips the Swift module prefix from NSPrincipalClass', () {
      const xml =
          '<key>NSPrincipalClass</key>\n\t<string>Runner.AppDelegate</string>';

      expect(
        InfoPlist.normalizeObjCClassNames(xml),
        '<key>NSPrincipalClass</key>\n\t<string>AppDelegate</string>',
      );
    });

    test('strips the Swift module prefix from UISceneDelegateClassName', () {
      const xml =
          '<key>UISceneDelegateClassName</key>\n'
          '\t<string>MyModule.SceneDelegate</string>';

      expect(
        InfoPlist.normalizeObjCClassNames(xml),
        '<key>UISceneDelegateClassName</key>\n\t<string>SceneDelegate</string>',
      );
    });

    test('leaves an unqualified class name unchanged', () {
      const xml = '<key>NSPrincipalClass</key>\n\t<string>AppDelegate</string>';

      expect(InfoPlist.normalizeObjCClassNames(xml), xml);
    });

    test('does not touch unrelated keys even if the value contains a dot', () {
      const xml =
          '<key>CFBundleExecutable</key>\n\t<string>Runner.App</string>';

      expect(InfoPlist.normalizeObjCClassNames(xml), xml);
    });
  });

  group('stripUnsatisfiableStoryboards', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xcross_info_plist_');
      Directory(
        p.join(tmp.path, 'Main.storyboardc'),
      ).createSync(recursive: true);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('keeps UIMainStoryboardFile when the storyboard is compiled', () {
      const xml = '<key>UIMainStoryboardFile</key>\n\t<string>Main</string>';

      expect(InfoPlist.stripUnsatisfiableStoryboards(xml, tmp.path), xml);
    });

    test('replaces a missing UILaunchStoryboardName with UILaunchScreen', () {
      const xml =
          '<key>UILaunchStoryboardName</key>\n\t<string>Missing</string>';

      expect(
        InfoPlist.stripUnsatisfiableStoryboards(xml, tmp.path),
        '<key>UILaunchScreen</key>\n\t<dict/>',
      );
    });

    test('strips a missing UILaunchStoryboardName without duplicating an '
        'existing UILaunchScreen', () {
      const xml =
          '<key>UILaunchScreen</key>\n\t<dict/>\n'
          '<key>UILaunchStoryboardName</key>\n\t<string>Missing</string>';

      final result = InfoPlist.stripUnsatisfiableStoryboards(xml, tmp.path);

      expect(result, '<key>UILaunchScreen</key>\n\t<dict/>\n');
      expect('UILaunchScreen'.allMatches(result).length, 1);
    });

    test('keeps UISceneStoryboardFile when the storyboard is compiled', () {
      const xml = '<key>UISceneStoryboardFile</key>\n\t<string>Main</string>';

      expect(InfoPlist.stripUnsatisfiableStoryboards(xml, tmp.path), xml);
    });

    test('strips a missing UISceneStoryboardFile with no UILaunchScreen '
        'substitution', () {
      const xml =
          '<key>UISceneStoryboardFile</key>\n\t<string>Missing</string>';

      final result = InfoPlist.stripUnsatisfiableStoryboards(xml, tmp.path);

      expect(result, isEmpty);
    });
  });

  group('fallback', () {
    test('is a well-formed plist that includes UILaunchScreen', () {
      expect(InfoPlist.fallback, contains('UILaunchScreen'));
      expect(InfoPlist.fallback, contains('<plist'));
      expect(InfoPlist.fallback, contains('</plist>'));
    });
  });
}
