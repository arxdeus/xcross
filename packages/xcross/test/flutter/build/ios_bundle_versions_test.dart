import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/ios_bundle_versions.dart';

import '../flutter_test_runtime.dart';

const _pbxproj = '''
{
	objects = {
		AA01 = {
			isa = PBXNativeTarget;
			buildConfigurationList = BB01;
			name = "Share Extension";
			productType = "com.apple.product-type.app-extension";
		};
		AA02 = {
			isa = PBXNativeTarget;
			buildConfigurationList = BB02;
			name = Runner;
			productType = "com.apple.product-type.application";
		};
		CC01 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				MARKETING_VERSION = 9.9.9;
				CURRENT_PROJECT_VERSION = 99;
			};
			name = Debug;
		};
		CC02 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				MARKETING_VERSION = 2.4.1;
				CURRENT_PROJECT_VERSION = 37;
			};
			name = Debug;
		};
		BB01 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				CC01,
			);
		};
		BB02 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				CC02,
			);
		};
	};
	rootObject = PP01;
}
''';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_bundle_versions-');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> writePbxproj(String contents) async {
    final dir = Directory(p.join(tmp.path, 'ios', 'Runner.xcodeproj'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'project.pbxproj')).writeAsString(contents);
  }

  test(
    testOn: '!windows',

    'reads versions from the application target, not an extension',
    () async {
      await writePbxproj(_pbxproj);

      final versions = testIPhoneRuntime().versions.resolve(tmp.path);

      expect(versions.shortVersion, '2.4.1');
      expect(versions.bundleVersion, '37');
    },
  );

  test(
    testOn: '!windows',
    'falls back when the project declares no versions',
    () async {
      await writePbxproj('{ objects = { }; }');

      final versions = testIPhoneRuntime().versions.resolve(tmp.path);

      expect(versions.shortVersion, IosBundleVersions.fallback.shortVersion);
      expect(versions.bundleVersion, IosBundleVersions.fallback.bundleVersion);
    },
  );

  test(
    testOn: '!windows',
    'falls back for a project with no Xcode project at all',
    () {
      final versions = testIPhoneRuntime().versions.resolve(tmp.path);

      expect(versions.shortVersion, '1.0.0');
      expect(versions.bundleVersion, '1');
    },
  );

  test(
    testOn: '!windows',
    'CLI build-name/build-number win over the project settings',
    () async {
      await writePbxproj(_pbxproj);

      final versions = testIPhoneRuntime().versions.resolve(
        tmp.path,
        buildName: '5.0.0',
        buildNumber: '500',
      );

      expect(versions.shortVersion, '5.0.0');
      expect(versions.bundleVersion, '500');
    },
  );

  test(testOn: '!windows', 'ignores an unresolved template value', () async {
    await writePbxproj(r'''
{
	objects = {
		AA02 = {
			isa = PBXNativeTarget;
			buildConfigurationList = BB02;
			name = Runner;
			productType = "com.apple.product-type.application";
		};
		CC02 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				MARKETING_VERSION = "$(INHERITED)";
			};
			name = Debug;
		};
		BB02 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				CC02,
			);
		};
	};
}
''');

    expect(
      testIPhoneRuntime().versions.resolve(tmp.path).shortVersion,
      '1.0.0',
    );
  });

  group('fromBuiltPlist', () {
    test(
      testOn: '!windows',
      'reads both versions out of a built Info.plist',
      () async {
        final plist = File(p.join(tmp.path, 'Info.plist'));
        await plist.writeAsString(
          '<dict>\n'
          '<key>CFBundleShortVersionString</key><string>3.2.1</string>\n'
          '<key>CFBundleVersion</key><string>42</string>\n'
          '</dict>',
        );

        final versions = testIPhoneRuntime().versions.fromBuiltPlist(
          plist.path,
        );

        expect(versions?.shortVersion, '3.2.1');
        expect(versions?.bundleVersion, '42');
      },
    );

    test('returns null for a plist still holding templates', () async {
      final plist = File(p.join(tmp.path, 'Info.plist'));
      await plist.writeAsString(
        '<dict>\n'
        r'<key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>'
        '\n<key>CFBundleVersion</key><string>1</string>\n'
        '</dict>',
      );

      expect(testIPhoneRuntime().versions.fromBuiltPlist(plist.path), isNull);
    });

    test('returns null when the file is absent', () {
      expect(
        testIPhoneRuntime().versions.fromBuiltPlist(
          p.join(tmp.path, 'nope.plist'),
        ),
        isNull,
      );
    });
  });
}
