import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/compose/build/compose_entitlements.dart';
import 'package:xcross/src/compose/compose.dart';

/// A Compose project that keeps its iOS app next to the shared module
/// (`app/iosApp` beside `app/shared`) instead of at the root.
void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('xcross_nested_ios_app_');
    root = temp.path;
  });
  tearDown(() => temp.deleteSync(recursive: true));

  void write(String relative, String content) => File(p.join(root, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  void nestedApp() {
    write('app/iosApp/Configuration/Config.xcconfig', r'''
// The bundle id lives in the Xcode project, not here.
PRODUCT_NAME=Nested
MARKETING_VERSION=3.1
API_BASE_URL=https:/$()/api.example.com
CLIENT_ID=12345
''');
    write('app/iosApp/iosApp/Info.plist', r'''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ApiBaseUrl</key><string>$(API_BASE_URL)</string>
<key>ClientId</key><string>${CLIENT_ID}</string>
<key>Unknown</key><string>before-$(NOT_DEFINED)-after</string>
<key>Schemes</key><array><string>app-$(PRODUCT_BUNDLE_IDENTIFIER)</string></array>
<key>Nested</key><dict><key>Name</key><string>$(PRODUCT_NAME)</string></dict>
</dict></plist>
''');
    write('app/iosApp/iosApp/Nested.entitlements', '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.developer.applesignin</key><array><string>Default</string></array>
</dict></plist>
''');
  }

  group('IosAppConfig.directory', () {
    test('prefers <root>/iosApp when it is an app', () {
      write('iosApp/Configuration/Config.xcconfig', 'PRODUCT_NAME=Root\n');
      nestedApp();
      expect(IosAppConfig.directory(root), p.join(root, 'iosApp'));
    });

    test('finds a single app one level down', () {
      nestedApp();
      expect(IosAppConfig.directory(root), p.join(root, 'app', 'iosApp'));
      expect(IosAppConfig.load(root)?.productName, 'Nested');
    });

    test("is not fooled by xcross's own runner build dir at the root", () {
      nestedApp();
      Directory(
        p.join(root, 'iosApp', '.build', 'runner'),
      ).createSync(recursive: true);
      expect(IosAppConfig.directory(root), p.join(root, 'app', 'iosApp'));
    });

    test('recognises an app by its Xcode project alone', () {
      Directory(
        p.join(root, 'mobile', 'iosApp', 'iosApp.xcodeproj'),
      ).createSync(recursive: true);
      expect(IosAppConfig.directory(root), p.join(root, 'mobile', 'iosApp'));
    });

    test('two nested apps are ambiguous and resolve to neither', () {
      nestedApp();
      write('other/iosApp/Info.plist', '<plist><dict/></plist>');
      expect(IosAppConfig.directory(root), isNull);
    });

    test('keeps every xcconfig setting, expanded', () {
      nestedApp();
      final settings = IosAppConfig.load(root)!.buildSettings;
      expect(settings['API_BASE_URL'], 'https://api.example.com');
      expect(settings['CLIENT_ID'], '12345');
    });
  });

  test(
    'Info.plist is read from the nested app with build settings expanded',
    () {
      nestedApp();
      final project = KmpProject(
        root: root,
        modulePath: p.join(root, 'app', 'shared'),
        moduleName: 'app:shared',
        baseName: 'Shared',
        entryKind: KmpEntryKind.runnableApp,
        bundleId: 'sg.example.nested',
        appName: 'Nested',
        iosConfig: IosAppConfig.load(root),
      );

      final plist =
          PropertyListSerialization.propertyListWithString(
                ComposeInfoPlist.build(project: project),
              )
              as Map;

      expect(plist['ApiBaseUrl'], 'https://api.example.com');
      expect(plist['ClientId'], '12345');
      expect(plist['Unknown'], 'before--after');
      expect(plist['Schemes'], ['app-sg.example.nested']);
      expect((plist['Nested'] as Map)['Name'], 'Nested');
      expect(plist['CFBundleIdentifier'], 'sg.example.nested');
      expect(plist['CFBundleShortVersionString'], '3.1');
    },
  );

  test('entitlements are found in the nested app', () {
    nestedApp();
    expect(
      ComposeEntitlements.find(root, 'Nested'),
      p.join(root, 'app', 'iosApp', 'iosApp', 'Nested.entitlements'),
    );
  });
}
