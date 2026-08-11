import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/project/ios_app_config.dart';

void main() {
  group('IosAppConfig', () {
    test('parses assignments and expands known variables', () {
      final config = IosAppConfig.parse(r'''
TEAM_ID =
PRODUCT_NAME = KotlinProject
PRODUCT_BUNDLE_IDENTIFIER = org.example.KotlinProject$(TEAM_ID)
MARKETING_VERSION = 1.2
CURRENT_PROJECT_VERSION = 7
''');

      expect(config.productName, 'KotlinProject');
      expect(config.bundleId, 'org.example.KotlinProject');
      expect(config.marketingVersion, '1.2');
      expect(config.currentProjectVersion, '7');
    });

    test('ignores comments and conditional key suffixes', () {
      final config = IosAppConfig.parse(r'''
// comment
PRODUCT_NAME[sdk=iphoneos*] = Shared App
# another comment
PRODUCT_BUNDLE_IDENTIFIER = org.example.$(PRODUCT_NAME)
''');

      expect(config.productName, 'Shared App');
      expect(config.bundleId, 'org.example.Shared App');
    });

    test('expands variables recursively across multiple hops', () {
      final config = IosAppConfig.parse(r'''
ORG = org
DOMAIN = $(ORG).example
APP_SEGMENT = $(APP_NAME)
APP_NAME = DeepApp
PRODUCT_NAME = $(APP_NAME)
PRODUCT_BUNDLE_IDENTIFIER = $(DOMAIN).$(APP_SEGMENT)
''');

      expect(config.productName, 'DeepApp');
      expect(config.bundleId, 'org.example.DeepApp');
    });

    test('defaults missing product and version values', () {
      final config = IosAppConfig.parse(
        'PRODUCT_BUNDLE_IDENTIFIER = org.example.app',
      );

      expect(config.productName, 'Runner');
      expect(config.bundleId, 'org.example.app');
      expect(config.marketingVersion, '1.0');
      expect(config.currentProjectVersion, '1');
    });

    test('load returns null when Config.xcconfig is missing', () {
      final root = Directory.systemTemp.createTempSync('xcross_ios_config_');
      addTearDown(() => root.deleteSync(recursive: true));

      expect(IosAppConfig.load(root.path), isNull);
    });

    test('load reads iosApp Configuration Config.xcconfig', () {
      final root = Directory.systemTemp.createTempSync('xcross_ios_config_');
      addTearDown(() => root.deleteSync(recursive: true));
      final configDir = Directory(p.join(root.path, 'iosApp', 'Configuration'))
        ..createSync(recursive: true);
      File(p.join(configDir.path, 'Config.xcconfig')).writeAsStringSync('''
PRODUCT_NAME = FromFile
PRODUCT_BUNDLE_IDENTIFIER = org.example.file
''');

      final config = IosAppConfig.load(root.path);

      expect(config, isNotNull);
      expect(config!.productName, 'FromFile');
      expect(config.bundleId, 'org.example.file');
    });
  });
}
