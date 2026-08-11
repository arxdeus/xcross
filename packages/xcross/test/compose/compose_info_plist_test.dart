import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/compose/compose.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/constants.dart';

void main() {
  test(
    'builds complete plist by preserving safe partials and forcing install keys',
    () {
      final fixture = _Fixture.create()..writePartialPlist();
      addTearDown(fixture.dispose);

      final xml = ComposeInfoPlist.build(
        project: fixture.project,
        extras: {
          'CADisableMinimumFrameDurationOnPhone': true,
          'CustomList': ['one', 2, false],
          'CustomDict': {'Nested': 'value'},
        },
      );
      final plist =
          PropertyListSerialization.propertyListWithString(xml) as Map;

      expect(plist['CFBundleExecutable'], 'Runner');
      expect(plist['CFBundleIdentifier'], 'dev.example.shared');
      expect(plist['CFBundleName'], 'Example');
      expect(plist['CFBundleDisplayName'], 'Example');
      expect(plist['CFBundleShortVersionString'], '2.0');
      expect(plist['CFBundleVersion'], '8');
      expect(plist['CFBundlePackageType'], 'APPL');
      expect(plist['LSRequiresIPhoneOS'], isTrue);
      expect(plist['MinimumOSVersion'], '15.0');
      expect(plist['CFBundleSupportedPlatforms'], ['iPhoneOS']);
      expect(plist['UIRequiredDeviceCapabilities'], ['arm64']);
      expect(plist['UIDeviceFamily'], [1]);
      expect(plist['UILaunchScreen'], isA<Map<Object?, Object?>>());
      expect(plist['DTPlatformName'], 'iphoneos');
      expect(plist['DTSDKName'], IosDeploymentConstants.sdkTriple);
      expect(plist['DTPlatformVersion'], IosDeploymentConstants.sdkVersion);
      expect(plist['PreservedPartialString'], 'keep');
      expect(plist['CADisableMinimumFrameDurationOnPhone'], isTrue);
      expect(plist['CustomList'], ['one', 2, false]);
      expect(plist['CustomDict'], {'Nested': 'value'});
    },
  );

  test('rejects unsafe extra and partial plist values', () {
    final fixture = _Fixture.create();
    addTearDown(fixture.dispose);

    expect(
      () => ComposeInfoPlist.build(
        project: fixture.project,
        extras: {'UnsafeDate': DateTime(2026)},
      ),
      throwsA(isA<XcrossError>()),
    );

    File(p.join(fixture.root, 'iosApp', 'Info.plist'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>UnsafeData</key><data>AA==</data></dict></plist>
''');
    expect(
      () => ComposeInfoPlist.build(project: fixture.project),
      throwsA(isA<XcrossError>()),
    );
  });
}

final class _Fixture {
  _Fixture._(this.temp) : root = temp.path;

  factory _Fixture.create() => _Fixture._(
    Directory.systemTemp.createTempSync('xcross_info_plist_test_'),
  );

  final Directory temp;
  final String root;

  KmpProject get project => KmpProject(
    root: root,
    modulePath: p.join(root, 'shared'),
    moduleName: 'shared',
    baseName: 'Shared',
    entryKind: KmpEntryKind.swiftApp,
    bundleId: 'dev.example.shared',
    appName: 'Example',
    iosConfig: const IosAppConfig(
      productName: 'Example',
      bundleId: 'dev.example.shared',
      marketingVersion: '2.0',
      currentProjectVersion: '8',
    ),
  );

  void writePartialPlist() {
    File(p.join(root, 'iosApp', 'Info.plist'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Wrong</string>
<key>MinimumOSVersion</key><string>12.0</string>
<key>PreservedPartialString</key><string>keep</string>
</dict></plist>
''');
  }

  Future<void> dispose() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  }
}
