import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';

/// A realistic two-target project: a Runner app plus one share extension.
const _pbxproj = r'''
// !$*UTF8*$!
{
	archiveVersion = 1;
	objectVersion = 54;
	objects = {
		AA01 /* Share Extension */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = BB01;
			buildPhases = (
				SS01,
				RR01,
			);
			name = "Share Extension";
			productName = "Share Extension";
			productType = "com.apple.product-type.app-extension";
		};
		AA02 /* Runner */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = BB02;
			buildPhases = (
			);
			name = Runner;
			productType = "com.apple.product-type.application";
		};
		SS01 = {
			isa = PBXSourcesBuildPhase;
			files = (
				FB01,
			);
		};
		RR01 = {
			isa = PBXResourcesBuildPhase;
			files = (
				FB02,
			);
		};
		FB01 = {
			isa = PBXBuildFile;
			fileRef = FR01;
		};
		FB02 = {
			isa = PBXBuildFile;
			fileRef = FR02;
		};
		FR01 = {
			isa = PBXFileReference;
			path = ShareViewController.swift;
			sourceTree = "<group>";
		};
		FR02 = {
			isa = PBXFileReference;
			path = MainInterface.storyboard;
			sourceTree = "<group>";
		};
		GR01 = {
			isa = PBXGroup;
			children = (
				FR01,
				GR02,
			);
			path = "Share Extension";
			sourceTree = "<group>";
		};
		GR02 = {
			isa = PBXGroup;
			children = (
				FR02,
			);
			path = Base.lproj;
			sourceTree = "<group>";
		};
		CC01 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.App.Share-Extension";
				INFOPLIST_FILE = "Share Extension/Info.plist";
				CODE_SIGN_ENTITLEMENTS = "Share Extension/Share Extension.entitlements";
				SWIFT_VERSION = 5.0;
				IPHONEOS_DEPLOYMENT_TARGET = 14.0;
			};
			name = Debug;
		};
		CC02 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = com.example.App;
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
    tmp = await Directory.systemTemp.createTemp('xcross_app_extensions-');
    final xcodeproj = Directory(p.join(tmp.path, 'ios', 'Runner.xcodeproj'));
    await xcodeproj.create(recursive: true);
    await File(
      p.join(xcodeproj.path, 'project.pbxproj'),
    ).writeAsString(_pbxproj);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> writeEntitlements(String contents) async {
    final dir = Directory(p.join(tmp.path, 'ios', 'Share Extension'));
    await dir.create(recursive: true);
    await File(
      p.join(dir.path, 'Share Extension.entitlements'),
    ).writeAsString(contents);
  }

  test('discovers only app-extension targets, never the application', () {
    final extensions = IosAppExtensions.discover(tmp.path);

    expect(extensions, hasLength(1));
    expect(extensions.single.name, 'Share Extension');
    expect(extensions.single.bundleId, 'com.example.App.Share-Extension');
  });

  test('resolves build settings and group-relative file paths', () {
    final extension = IosAppExtensions.discover(tmp.path).single;
    final ios = p.join(tmp.path, 'ios');

    expect(extension.swiftVersion, '5.0');
    expect(extension.deploymentTarget, '14.0');
    expect(
      extension.infoPlistPath,
      p.join(ios, 'Share Extension', 'Info.plist'),
    );
    expect(extension.sources, [
      p.join(ios, 'Share Extension', 'ShareViewController.swift'),
    ]);
    // Nested PBXGroup paths must both contribute: "Share Extension/Base.lproj".
    expect(extension.resources, [
      p.join(ios, 'Share Extension', 'Base.lproj', 'MainInterface.storyboard'),
    ]);
  });

  test('reports the bundle name and Xcode-style Swift module name', () {
    final extension = IosAppExtensions.discover(tmp.path).single;

    expect(extension.bundleName, 'Share Extension.appex');
    expect(extension.moduleName, 'Share_Extension');
  });

  test('computes the suffix under the host app id', () {
    final extension = IosAppExtensions.discover(tmp.path).single;

    expect(extension.suffixUnder('com.example.App'), '.Share-Extension');
    // An extension outside the app's id namespace is not installable.
    expect(extension.suffixUnder('com.other.App'), isNull);
  });

  test('reads app groups from the entitlements file', () async {
    await writeEntitlements('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.example.Shared</string>
	</array>
</dict>
</plist>
''');

    expect(IosAppExtensions.discover(tmp.path).single.appGroups, [
      'group.com.example.Shared',
    ]);
  });

  test('ignores templated app groups that cannot be provisioned', () async {
    await writeEntitlements(r'''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$(CUSTOM_GROUP_ID)</string>
	</array>
</dict>
</plist>
''');

    expect(IosAppExtensions.discover(tmp.path).single.appGroups, isEmpty);
  });

  test('returns nothing for a project without an Xcode project', () async {
    final empty = await Directory.systemTemp.createTemp('xcross_no_ios-');
    addTearDown(() => empty.delete(recursive: true));

    expect(IosAppExtensions.discover(empty.path), isEmpty);
  });

  test('tolerates a malformed pbxproj instead of failing the build', () async {
    await File(
      p.join(tmp.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'),
    ).writeAsString('{ this is not a valid pbxproj');

    expect(IosAppExtensions.discover(tmp.path), isEmpty);
  });

  test('finds the application target name', () {
    expect(IosAppExtensions.applicationTargetName(tmp.path), 'Runner');
  });

  group('Xcode 16 synchronized folder groups', () {
    late Directory synced;

    /// A project whose extension target lists no files in its build phases and
    /// instead points at a synchronized folder group, the shape Xcode 16
    /// writes for a target added with "folder" references.
    Future<void> writeSyncedProject({String exceptions = ''}) async {
      await File(
        p.join(tmp.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'),
      ).writeAsString('''
// !\$*UTF8*\$!
{
	archiveVersion = 1;
	objectVersion = 77;
	objects = {
		AA01 = {
			isa = PBXNativeTarget;
			buildConfigurationList = BB01;
			buildPhases = (
				SS01,
			);
			fileSystemSynchronizedGroups = (
				SG01,
			);
			name = "Share Extension";
			productType = "com.apple.product-type.app-extension";
		};
		SG01 = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = "Share Extension";
			sourceTree = "<group>";
$exceptions
		};
		SS01 = {
			isa = PBXSourcesBuildPhase;
			files = (
			);
		};
		CC01 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				INFOPLIST_FILE = "Share Extension/Info.plist";
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.App.Share-Extension";
			};
			name = Debug;
		};
		BB01 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				CC01,
			);
		};
	};
	rootObject = PP01;
}
''');
    }

    setUp(() async {
      synced = Directory(p.join(tmp.path, 'ios', 'Share Extension'));
      await Directory(
        p.join(synced.path, 'Base.lproj'),
      ).create(recursive: true);
      await File(
        p.join(synced.path, 'ShareViewController.swift'),
      ).writeAsString('class ShareViewController {}');
      await File(
        p.join(synced.path, 'Base.lproj', 'MainInterface.storyboard'),
      ).writeAsString('<document/>');
      await File(p.join(synced.path, 'Info.plist')).writeAsString('<plist/>');
      await File(
        p.join(synced.path, 'Settings.plist'),
      ).writeAsString('<plist/>');
    });

    test('recovers sources from a synchronized folder group', () async {
      await writeSyncedProject();

      final extension = IosAppExtensions.discover(tmp.path).single;

      expect(extension.sources, [
        p.join(synced.path, 'ShareViewController.swift'),
      ]);
    });

    test('classifies synchronized files as sources or resources', () async {
      await writeSyncedProject();

      final extension = IosAppExtensions.discover(tmp.path).single;

      // Nested folders and arbitrary plists contribute, while the target's
      // Info.plist remains a build input that the builder writes itself.
      expect(extension.resources, [
        p.join(synced.path, 'Base.lproj', 'MainInterface.storyboard'),
        p.join(synced.path, 'Settings.plist'),
      ]);
      expect(extension.resources, isNot(contains(endsWith('Info.plist'))));
    });

    test('honours membership exceptions for this target', () async {
      await writeSyncedProject(
        exceptions: '''
			exceptions = (
				EX01,
			);''',
      );
      final pbxproj = File(
        p.join(tmp.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'),
      );
      await pbxproj.writeAsString(
        pbxproj.readAsStringSync().replaceFirst('		SS01 = {', '''
		EX01 = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			target = AA01;
			membershipExceptions = (
				ShareViewController.swift,
			);
		};
		SS01 = {'''),
      );

      expect(IosAppExtensions.discover(tmp.path).single.sources, isEmpty);
    });

    test('ignores exceptions belonging to a different target', () async {
      await writeSyncedProject(
        exceptions: '''
			exceptions = (
				EX01,
			);''',
      );
      final pbxproj = File(
        p.join(tmp.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'),
      );
      await pbxproj.writeAsString(
        pbxproj.readAsStringSync().replaceFirst('		SS01 = {', '''
		EX01 = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			target = AA99;
			membershipExceptions = (
				ShareViewController.swift,
			);
		};
		SS01 = {'''),
      );

      expect(IosAppExtensions.discover(tmp.path).single.sources, hasLength(1));
    });

    test('tolerates a synchronized group with no folder on disk', () async {
      await writeSyncedProject();
      await synced.delete(recursive: true);

      final extension = IosAppExtensions.discover(tmp.path).single;

      expect(extension.sources, isEmpty);
      expect(extension.resources, isEmpty);
    });
  });
}
