import 'dart:io';
import 'dart:isolate';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/compose/compose.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/constants.dart';

import 'support/compose_platforms.dart';

void main() {
  late ComposeTestSession session;
  setUp(() {
    session = ComposeTestSession();
  });
  tearDown(() => session.dispose());
  test(
    'builds complete plist by preserving safe partials and forcing install keys',
    () {
      final fixture = ComposeFixture.create()..writePartialPlist();
      addTearDown(fixture.dispose);

      final xml =
          ComposeInfoPlist(
            session.fixtureRunner.host.fileSystem,
            session.fixtureLog,
          ).build(
            project: fixture.project,
            extras: {
              'CADisableMinimumFrameDurationOnPhone': true,
              'CustomList': ['one', 2, false],
              'CustomDict': {'Nested': 'value'},
            },
            target: const IPhoneBuildPlatform(),
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

  test('adds CADisableMinimumFrameDurationOnPhone without being asked', () {
    // Compose UI's PlistSanityCheck throws at startup when this key is
    // absent, which crashed the app (SIGABRT) to a black screen on device.
    final fixture = ComposeFixture.create();
    addTearDown(fixture.dispose);

    final plist =
        PropertyListSerialization.propertyListWithString(
              ComposeInfoPlist(
                session.fixtureRunner.host.fileSystem,
                session.fixtureLog,
              ).build(
                project: fixture.project,
                target: const IPhoneBuildPlatform(),
              ),
            )
            as Map;

    expect(plist['CADisableMinimumFrameDurationOnPhone'], isTrue);
  });

  test('lets the project opt out of the Compose plist defaults', () {
    final fixture = ComposeFixture.create();
    addTearDown(fixture.dispose);

    final plist =
        PropertyListSerialization.propertyListWithString(
              ComposeInfoPlist(
                session.fixtureRunner.host.fileSystem,
                session.fixtureLog,
              ).build(
                target: const IPhoneBuildPlatform(),
                project: fixture.project,
                extras: {'CADisableMinimumFrameDurationOnPhone': false},
              ),
            )
            as Map;

    expect(plist['CADisableMinimumFrameDurationOnPhone'], isFalse);
  });

  test('uses resolved project identity over xcconfig identity', () {
    final fixture = ComposeFixture.create();
    addTearDown(fixture.dispose);
    final project = KmpProject(
      root: fixture.root,
      modulePath: p.join(fixture.root, 'shared'),
      moduleName: 'shared',
      baseName: 'Shared',
      entryKind: KmpEntryKind.swiftApp,
      bundleId: 'dev.example.override',
      appName: 'OverrideApp',
      iosConfig: const IosAppConfig(
        productName: 'XcconfigApp',
        bundleId: 'dev.example.xcconfig',
        marketingVersion: '2.0',
        currentProjectVersion: '8',
      ),
    );

    final xml = ComposeInfoPlist(
      session.fixtureRunner.host.fileSystem,
      session.fixtureLog,
    ).build(project: project, target: const IPhoneBuildPlatform());
    final plist = PropertyListSerialization.propertyListWithString(xml) as Map;

    expect(plist['CFBundleIdentifier'], 'dev.example.override');
    expect(plist['CFBundleName'], 'OverrideApp');
    expect(plist['CFBundleDisplayName'], 'OverrideApp');
    expect(plist['CFBundleShortVersionString'], '2.0');
    expect(plist['CFBundleVersion'], '8');
  });

  test(
    'real Swift host example preserves safe partial plist keys and overrides required keys',
    () {
      final project = session.detectKmpProject(
        p.join(_repoRoot, 'examples', 'kmp_swift_app'),
      );

      final xml = ComposeInfoPlist(
        session.fixtureRunner.host.fileSystem,
        session.fixtureLog,
      ).build(project: project, target: const IPhoneBuildPlatform());
      final plist =
          PropertyListSerialization.propertyListWithString(xml) as Map;

      expect(project.entryKind, KmpEntryKind.swiftApp);
      expect(plist['XCROSSPreservedExampleKey'], 'kept from example partial');
      expect(plist['CFBundleExecutable'], 'Runner');
      expect(plist['CFBundleIdentifier'], 'org.example.KmpSwiftApp');
      expect(plist['CFBundleName'], 'KmpSwiftApp');
      expect(plist['MinimumOSVersion'], '15.0');
      expect(plist['UILaunchScreen'], isA<Map<Object?, Object?>>());
    },
  );

  test('rejects unsafe extra and partial plist values', () {
    final fixture = ComposeFixture.create();
    addTearDown(fixture.dispose);

    expect(
      () =>
          ComposeInfoPlist(
            session.fixtureRunner.host.fileSystem,
            session.fixtureLog,
          ).build(
            project: fixture.project,
            extras: {'UnsafeDate': DateTime(2026)},
            target: const IPhoneBuildPlatform(),
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
      () => ComposeInfoPlist(
        session.fixtureRunner.host.fileSystem,
        session.fixtureLog,
      ).build(project: fixture.project, target: const IPhoneBuildPlatform()),
      throwsA(isA<XcrossError>()),
    );
  });
}

final String _repoRoot = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:xcross/xcross.dart'))!,
).parent.parent.parent.parent.path;

final class ComposeFixture {
  ComposeFixture._(this.temp) : root = temp.path;

  factory ComposeFixture.create() => ComposeFixture._(
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
