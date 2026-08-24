import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/info_plist.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/constants.dart';

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
        deploymentTarget: const IosDeploymentTarget('15.6'),
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
          '\t<string>15.6</string>',
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

    test(
      'overwrites an existing MinimumOSVersion value with resolved target',
      () {
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
          deploymentTarget: const IosDeploymentTarget('15.6'),
        );

        expect(
          result,
          contains('<key>MinimumOSVersion</key>\n\t<string>15.6</string>'),
        );
        expect(result, isNot(contains('<string>15.5</string>')));
        expect('<key>MinimumOSVersion</key>'.allMatches(result).length, 1);
      },
    );

    // Regression check: this runs on every build, so without the presence
    // guards in `_ensureKey` a rebuild would pile up duplicate <key> pairs.
    test('applying twice does not duplicate ensure-only keys', () {
      final once = InfoPlist.applyIosRequiredKeys(
        _minimalPlist,
        bundleId: 'com.example.app',
        deploymentTarget: IosDeploymentTarget.fallback,
      );
      final twice = InfoPlist.applyIosRequiredKeys(
        once,
        bundleId: 'com.example.app',
        deploymentTarget: IosDeploymentTarget.fallback,
      );

      expect('<key>UIDeviceFamily</key>'.allMatches(twice).length, 1);
      expect('<key>LSRequiresIPhoneOS</key>'.allMatches(twice).length, 1);
      expect('<key>DTPlatformVersion</key>'.allMatches(twice).length, 1);
      expect('<key>CFBundleExecutable</key>'.allMatches(twice).length, 1);
    });
  });

  group('applySceneLifecycle', () {
    test('adds a programmatic SceneDelegate manifest', () {
      final result = InfoPlist.applySceneLifecycle(_minimalPlist);

      expect(result, contains('<key>UIApplicationSceneManifest</key>'));
      expect(result, contains('<string>UIWindowScene</string>'));
      expect(
        result,
        contains(
          '<key>UISceneDelegateClassName</key>\n'
          '\t\t\t\t\t<string>SceneDelegate</string>',
        ),
      );
      expect(result, isNot(contains('UISceneStoryboardFile')));
    });

    test('completes an existing empty manifest', () {
      const xml =
          '<?xml version="1.0"?>\n'
          '<plist version="1.0">\n'
          '<dict>\n'
          '\t<key>UIApplicationSceneManifest</key>\n'
          '\t<dict/>\n'
          '</dict>\n'
          '</plist>\n';

      final result = InfoPlist.applySceneLifecycle(xml);

      expect('UIApplicationSceneManifest'.allMatches(result).length, 1);
      expect(result, contains('<string>SceneDelegate</string>'));
    });

    test('replaces only the application scene role', () {
      const xml =
          '<?xml version="1.0"?>\n'
          '<plist version="1.0">\n'
          '<dict>\n'
          '\t<key>UIApplicationSceneManifest</key>\n'
          '\t<dict>\n'
          '\t\t<key>UISceneConfigurations</key>\n'
          '\t\t<dict>\n'
          '\t\t\t<key>UIWindowSceneSessionRoleApplication</key>\n'
          '\t\t\t<array><dict>\n'
          '\t\t\t\t<key>UISceneDelegateClassName</key>\n'
          '\t\t\t\t<string>Runner.CustomSceneDelegate</string>\n'
          '\t\t\t</dict></array>\n'
          '\t\t\t<key>UIWindowSceneSessionRoleExternalDisplay</key>\n'
          '\t\t\t<array><dict>\n'
          '\t\t\t\t<key>UISceneDelegateClassName</key>\n'
          '\t\t\t\t<string>Runner.ExternalSceneDelegate</string>\n'
          '\t\t\t</dict></array>\n'
          '\t\t</dict>\n'
          '\t</dict>\n'
          '</dict>\n'
          '</plist>\n';

      final result = InfoPlist.applySceneLifecycle(xml);

      expect(result, contains('<string>SceneDelegate</string>'));
      expect(result, isNot(contains('CustomSceneDelegate')));
      expect(result, contains('UIWindowSceneSessionRoleExternalDisplay'));
      expect(result, contains('Runner.ExternalSceneDelegate'));
    });

    test(
      'replaces a self-closing application role without touching others',
      () {
        const xml =
            '<?xml version="1.0"?>\n'
            '<plist version="1.0">\n'
            '<dict>\n'
            '\t<key>UIApplicationSceneManifest</key>\n'
            '\t<dict>\n'
            '\t\t<key>UISceneConfigurations</key>\n'
            '\t\t<dict>\n'
            '\t\t\t<key>UIWindowSceneSessionRoleApplication</key>\n'
            '\t\t\t<array/>\n'
            '\t\t\t<key>UIWindowSceneSessionRoleExternalDisplay</key>\n'
            '\t\t\t<array><dict>\n'
            '\t\t\t\t<key>UISceneDelegateClassName</key>\n'
            '\t\t\t\t<string>Runner.ExternalSceneDelegate</string>\n'
            '\t\t\t</dict></array>\n'
            '\t\t</dict>\n'
            '\t</dict>\n'
            '</dict>\n'
            '</plist>\n';

        final result = InfoPlist.applySceneLifecycle(xml);

        expect(result, contains('<string>SceneDelegate</string>'));
        expect(result, contains('UIWindowSceneSessionRoleExternalDisplay'));
        expect(result, contains('Runner.ExternalSceneDelegate'));
      },
    );

    test('leaves a malformed manifest untouched', () {
      const xml =
          '<?xml version="1.0"?>\n'
          '<plist version="1.0">\n'
          '<dict>\n'
          '\t<key>UIApplicationSceneManifest</key>\n'
          '\t<string>invalid</string>\n'
          '\t<key>UILaunchScreen</key>\n'
          '\t<dict/>\n'
          '</dict>\n'
          '</plist>\n';

      expect(InfoPlist.applySceneLifecycle(xml), xml);
    });

    test('adds the application role to a partial manifest', () {
      const xml =
          '<?xml version="1.0"?>\n'
          '<plist version="1.0">\n'
          '<dict>\n'
          '\t<key>UIApplicationSceneManifest</key>\n'
          '\t<dict>\n'
          '\t\t<key>UISceneConfigurations</key>\n'
          '\t\t<dict/>\n'
          '\t</dict>\n'
          '</dict>\n'
          '</plist>\n';

      final result = InfoPlist.applySceneLifecycle(xml);

      expect(result, contains('UIWindowSceneSessionRoleApplication'));
      expect(result, contains('<string>SceneDelegate</string>'));
    });

    test('is idempotent', () {
      final once = InfoPlist.applySceneLifecycle(_minimalPlist);
      final twice = InfoPlist.applySceneLifecycle(once);

      expect(twice, once);
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

  group('setPlistString', () {
    test('replaces every occurrence of a duplicated key', () {
      // Apple's plist parser resolves a duplicated key to the *last* entry,
      // so rewriting only the first would leave the stale value in force.
      const xml =
          '<?xml version="1.0"?>\n'
          '<plist version="1.0">\n'
          '<dict>\n'
          '\t<key>AppGroupId</key>\n'
          '\t<string>group.original</string>\n'
          '\t<key>AppGroupId</key>\n'
          '\t<string>group.original</string>\n'
          '</dict>\n'
          '</plist>\n';

      final updated = InfoPlist.setPlistString(
        xml,
        'AppGroupId',
        'group.qualified',
      );

      expect(updated, isNot(contains('group.original')));
      expect(
        RegExp('group.qualified').allMatches(updated).length,
        2,
        reason: 'both declarations must be rewritten',
      );
    });

    test('inserts the key when the template lacks it', () {
      final updated = InfoPlist.setPlistString(
        _minimalPlist,
        'AppGroupId',
        'group.qualified',
      );

      expect(updated, contains('<key>AppGroupId</key>'));
      expect(updated, contains('<string>group.qualified</string>'));
    });
  });

  group('rewriteUrlSchemes', () {
    const xml =
        '<?xml version="1.0"?>\n'
        '<plist version="1.0">\n'
        '<dict>\n'
        '\t<key>CFBundleIdentifier</key>\n'
        '\t<string>com.example.App</string>\n'
        '\t<key>CFBundleURLTypes</key>\n'
        '\t<array>\n'
        '\t\t<dict>\n'
        '\t\t\t<key>CFBundleURLSchemes</key>\n'
        '\t\t\t<array>\n'
        '\t\t\t\t<string>ShareMedia-com.example.App</string>\n'
        '\t\t\t\t<string>myapp</string>\n'
        '\t\t\t</array>\n'
        '\t\t</dict>\n'
        '\t</array>\n'
        '</dict>\n'
        '</plist>\n';

    test('qualifies a scheme derived from the bundle id', () {
      // The extension opens ShareMedia-<qualified id> at runtime, so the app
      // has to declare that exact scheme or nothing handles the redirect.
      final updated = InfoPlist.rewriteUrlSchemes(
        xml,
        from: 'com.example.App',
        to: 'XCR-ABC.com.example.App',
      );

      expect(
        updated,
        contains('<string>ShareMedia-XCR-ABC.com.example.App</string>'),
      );
    });

    test('leaves unrelated schemes alone', () {
      final updated = InfoPlist.rewriteUrlSchemes(
        xml,
        from: 'com.example.App',
        to: 'XCR-ABC.com.example.App',
      );

      expect(updated, contains('<string>myapp</string>'));
    });

    test('never touches values outside the scheme arrays', () {
      // CFBundleIdentifier is rewritten by its own dedicated step; a blanket
      // replace would corrupt any key that mentions the original id.
      final updated = InfoPlist.rewriteUrlSchemes(
        xml,
        from: 'com.example.App',
        to: 'XCR-ABC.com.example.App',
      );

      expect(
        updated,
        contains(
          '<key>CFBundleIdentifier</key>\n\t<string>com.example.App</string>',
        ),
      );
    });

    test('is a no-op when the id is unchanged', () {
      expect(
        InfoPlist.rewriteUrlSchemes(
          xml,
          from: 'com.example.App',
          to: 'com.example.App',
        ),
        xml,
      );
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
