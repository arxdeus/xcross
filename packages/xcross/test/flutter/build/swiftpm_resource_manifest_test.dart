import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/flutter_framework_copier.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';

import '../../apple/support/native_test_file_system.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('xcross-manifest-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  FlutterFrameworkCopier copierFor() {
    const fileSystem = NativeTestFileSystem();
    return FlutterFrameworkCopier(
      fileSystem,
      p.context,
      copier: RecursiveDirectoryCopier(
        fileSystem: fileSystem,
        paths: p.context,
      ),
    );
  }

  test(
    testOn: '!windows',
    'copies manifest resources from their sources like Xcode',
    () async {
      // SDWebImage: `.copy("Resources/PrivacyInfo.xcprivacy")` is a link to
      // `../../WebImage/PrivacyInfo.xcprivacy`; `swift build` copies the
      // link itself, so it dangles in the built bundle.
      final checkout = p.join(tmp.path, 'checkouts', 'SDWebImage');
      File(p.join(checkout, 'WebImage', 'PrivacyInfo.xcprivacy'))
        ..createSync(recursive: true)
        ..writeAsStringSync('privacy');
      final resources = p.join(checkout, 'SDWebImage', 'Resources');
      Directory(resources).createSync(recursive: true);
      Link(
        p.join(resources, 'PrivacyInfo.xcprivacy'),
      ).createSync(p.join('..', '..', 'WebImage', 'PrivacyInfo.xcprivacy'));
      File(p.join(checkout, 'Shared', 'outside.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('outside');
      final dir = Directory(p.join(resources, 'Dir'))..createSync();
      File(p.join(dir.path, 'own.txt')).writeAsStringSync('own');
      File(p.join(dir.path, '.DS_Store')).writeAsStringSync('junk');
      Link(p.join(dir.path, 'internal.txt')).createSync('own.txt');
      Link(
        p.join(dir.path, 'escape.txt'),
      ).createSync(p.join('..', '..', '..', 'Shared', 'outside.txt'));
      Link(p.join(dir.path, 'gone.txt')).createSync(p.join('..', 'nope.txt'));

      final built = p.join(tmp.path, 'debug', 'SDWebImage_SDWebImage.bundle');
      Directory(p.join(built, 'Dir')).createSync(recursive: true);
      Link(
        p.join(built, 'PrivacyInfo.xcprivacy'),
      ).createSync(p.join('..', '..', 'WebImage', 'PrivacyInfo.xcprivacy'));
      File(p.join(built, 'Info.plist')).writeAsStringSync('info');

      final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
      final warnings = <String>[];
      await copierFor().copyResourceBundles(
        [
          SwiftPmResourceBundle(
            bundlePath: built,
            resources: [
              SwiftPmBundleResource(
                source: p.join(resources, 'PrivacyInfo.xcprivacy'),
                relative: 'PrivacyInfo.xcprivacy',
              ),
              SwiftPmBundleResource(source: dir.path, relative: 'Dir'),
            ],
          ),
        ],
        app.path,
        warn: warnings.add,
        infoPlist: (_, region) => 'generated $region',
      );

      final bundle = p.join(app.path, 'SDWebImage_SDWebImage.bundle');
      final privacy = p.join(bundle, 'PrivacyInfo.xcprivacy');
      expect(FileSystemEntity.isLinkSync(privacy), isFalse);
      expect(File(privacy).readAsStringSync(), 'privacy');
      // Xcode's Info.plist always replaces whatever SwiftPM wrote.
      expect(
        File(p.join(bundle, 'Info.plist')).readAsStringSync(),
        'generated en',
      );
      expect(
        Link(p.join(bundle, 'Dir', 'internal.txt')).targetSync(),
        'own.txt',
      );
      final escape = p.join(bundle, 'Dir', 'escape.txt');
      expect(FileSystemEntity.isLinkSync(escape), isFalse);
      expect(File(escape).readAsStringSync(), 'outside');
      expect(File(p.join(bundle, 'Dir', '.DS_Store')).existsSync(), isFalse);
      expect(File(p.join(bundle, 'Dir', 'gone.txt')).existsSync(), isFalse);
      expect(warnings, [contains('gone.txt')]);
    },
  );

  test('copies sources and writes an Info.plist SwiftPM did not', () async {
    final source = p.join(tmp.path, 'src', 'PrivacyInfo.xcprivacy');
    File(source)
      ..createSync(recursive: true)
      ..writeAsStringSync('privacy');
    final built = p.join(tmp.path, 'debug', 'Pkg_T.bundle');
    File(p.join(built, 'PrivacyInfo.xcprivacy'))
      ..createSync(recursive: true)
      ..writeAsStringSync('stale');
    final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
    await copierFor().copyResourceBundles(
      [
        SwiftPmResourceBundle(
          bundlePath: built,
          resources: [
            SwiftPmBundleResource(
              source: source,
              relative: 'PrivacyInfo.xcprivacy',
            ),
          ],
        ),
      ],
      app.path,
      infoPlist: (bundle, _) => p.basename(bundle.bundlePath),
    );
    final bundle = p.join(app.path, 'Pkg_T.bundle');
    expect(
      File(p.join(bundle, 'PrivacyInfo.xcprivacy')).readAsStringSync(),
      'privacy',
    );
    expect(
      File(p.join(bundle, 'Info.plist')).readAsStringSync(),
      'Pkg_T.bundle',
    );
  });

  test('builds a declared bundle swift build did not recreate', () async {
    final source = p.join(tmp.path, 'src', 'PrivacyInfo.xcprivacy');
    File(source)
      ..createSync(recursive: true)
      ..writeAsStringSync('privacy');
    // No built directory: llbuild skipped the dangling copy after a wipe.
    final built = p.join(tmp.path, 'debug', 'SDWebImage_SDWebImage.bundle');
    final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
    await copierFor().copyResourceBundles(
      [
        SwiftPmResourceBundle(
          bundlePath: built,
          resources: [
            SwiftPmBundleResource(
              source: source,
              relative: 'PrivacyInfo.xcprivacy',
            ),
          ],
        ),
      ],
      app.path,
      infoPlist: (_, region) => 'generated $region',
    );
    final bundle = p.join(app.path, 'SDWebImage_SDWebImage.bundle');
    expect(
      File(p.join(bundle, 'PrivacyInfo.xcprivacy')).readAsStringSync(),
      'privacy',
    );
    expect(
      File(p.join(bundle, 'Info.plist')).readAsStringSync(),
      'generated en',
    );
  });

  test("replaces SwiftPM's partial Info.plist, keeping its region", () async {
    final built = p.join(tmp.path, 'debug', 'GoogleSignIn_GoogleSignIn.bundle');
    File(p.join(built, 'Info.plist'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n'
        '<dict>\n<key>CFBundleDevelopmentRegion</key>\n<string>fr</string>\n'
        '</dict>\n</plist>\n',
      );
    final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
    await copierFor().copyResourceBundles(
      [
        SwiftPmResourceBundle(
          bundlePath: built,
          resources: const [],
          packageIdentity: 'googlesignin-ios',
          targetName: 'GoogleSignIn',
        ),
      ],
      app.path,
      infoPlist: (bundle, region) => swiftPmResourceBundleInfoPlist(
        bundle,
        deploymentTarget: '13.0',
        device: true,
        paths: p.context,
        developmentRegion: region,
      ),
    );
    final xml = File(
      p.join(app.path, 'GoogleSignIn_GoogleSignIn.bundle', 'Info.plist'),
    ).readAsStringSync();
    expect(xml, contains('<string>BNDL</string>'));
    expect(
      xml,
      contains('<string>googlesignin-ios.GoogleSignIn.resources</string>'),
    );
    expect(swiftPmDevelopmentRegion(xml), 'fr');
  });

  test('a source resource replaces a generated copy of it', () async {
    // On Windows the coverage check once missed, so the built copy landed
    // first and File.copy (which never overwrites there) threw.
    final source = p.join(tmp.path, 'src', 'PrivacyInfo.xcprivacy');
    File(source)
      ..createSync(recursive: true)
      ..writeAsStringSync('source');
    final stale = p.join(tmp.path, 'stale', 'PrivacyInfo.xcprivacy');
    File(stale)
      ..createSync(recursive: true)
      ..writeAsStringSync('built');
    final built = p.join(tmp.path, 'debug', 'Pkg_T.bundle');
    Directory(built).createSync(recursive: true);
    final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
    await copierFor().copyResourceBundles([
      SwiftPmResourceBundle(
        bundlePath: built,
        resources: [
          SwiftPmBundleResource(
            source: stale,
            relative: 'PrivacyInfo.xcprivacy',
          ),
          SwiftPmBundleResource(
            source: source,
            relative: 'PrivacyInfo.xcprivacy',
          ),
        ],
      ),
    ], app.path);
    expect(
      File(
        p.join(app.path, 'Pkg_T.bundle', 'PrivacyInfo.xcprivacy'),
      ).readAsStringSync(),
      'source',
    );
  });

  test('resource coverage ignores Windows separator and case', () {
    final windows = p.Context(style: p.Style.windows);
    expect(
      resourceCoverage(windows, r'Resources\PrivacyInfo.xcprivacy', {
        'resources/privacyinfo.xcprivacy',
      }),
      ResourceCoverage.covered,
    );
    expect(
      resourceCoverage(windows, 'Resources', {
        'Resources/PrivacyInfo.xcprivacy',
      }),
      ResourceCoverage.holdsResource,
    );
    expect(
      resourceCoverage(windows, 'Info.plist', {'PrivacyInfo.xcprivacy'}),
      ResourceCoverage.none,
    );
  });

  group('manifest parsing', () {
    test('groups copy-tool commands by bundle', () {
      const manifest = r'''
commands:
  "/s/.build/ios/debug/P_T.bundle/Dir":
    tool: copy-tool
    inputs: ["/src/P/Res/Dir/"]
    outputs: ["/s/.build/ios/debug/P_T.bundle/Dir/"]
    description: "Copying"

  "/s/.build/ios/debug/P_T.bundle/a.json":
    tool: copy-tool
    inputs: ["/src/P/a \"q\".json"]
    outputs: ["/s/.build/ios/debug/P_T.bundle/a \"q\".json"]

  "/s/.build/ios/debug/other.txt":
    tool: copy-tool
    inputs: ["/src/other.txt"]
    outputs: ["/s/.build/ios/debug/other.txt"]

  "/s/.build/ios/debug/P_T.bundle/x":
    tool: write-auxiliary-file
    inputs: ["<x>"]
    outputs: ["/s/.build/ios/debug/P_T.bundle/x"]
''';
      expect(
        parseSwiftPmResourceCopies(manifest, p.Context(style: p.Style.posix)),
        {
          'P_T.bundle': [
            const SwiftPmBundleResource(
              source: '/src/P/Res/Dir',
              relative: 'Dir',
            ),
            const SwiftPmBundleResource(
              source: '/src/P/a "q".json',
              relative: 'a "q".json',
            ),
          ],
        },
      );
    });

    test('reads Windows paths', () {
      const manifest = r'''
commands:
  "C:\\b\\P_T.bundle\\Res":
    tool: copy-tool
    inputs: ["C:\\src\\P\\Res\\"]
    outputs: ["C:\\b\\debug\\P_T.bundle\\Res\\Sub\\"]
''';
      expect(
        parseSwiftPmResourceCopies(manifest, p.Context(style: p.Style.windows)),
        {
          'P_T.bundle': [
            const SwiftPmBundleResource(
              source: r'C:\src\P\Res',
              relative: r'Res\Sub',
            ),
          ],
        },
      );
    });

    test('reads per-target deployment versions', () {
      const manifest = '''
commands:
  "C.module":
    tool: shell
    args: ["swiftc","-module-name","FirebaseCore","-target","arm64-apple-ios15.0","-o","/b/FirebaseCore.build/x.o"]
  "D.module":
    tool: clang
    args: ["clang","-target","arm64-apple-ios12.0-simulator","-c","/s/a.m","-o","/b/nanopb.build/a.m.o"]
''';
      expect(parseSwiftPmTargetDeploymentVersions(manifest), {
        'FirebaseCore': '15.0',
        'nanopb': '12.0',
      });
    });
  });

  group('bundle identity', () {
    final posix = p.Context(style: p.Style.posix);
    test('package identity from workspace state', () {
      const state = '''
{"object":{"dependencies":[
 {"packageRef":{"identity":"firebase-ios-sdk","kind":"remoteSourceControl","location":"https://github.com/firebase/firebase-ios-sdk.git"},"subpath":"firebase-ios-sdk"},
 {"packageRef":{"identity":"file_picker_darwin-1.0.4","kind":"fileSystem","location":"/p/.packages/file_picker_darwin-1.0.4"},"subpath":"file_picker_darwin-1.0.4"}
]}}''';
      final locations = parseSwiftPmPackageLocations(state, '/s', posix);
      expect(
        packageIdentityOf(
          '/s/checkouts/firebase-ios-sdk/FirebaseCore/PrivacyInfo.xcprivacy',
          locations,
          posix,
        ),
        'firebase-ios-sdk',
      );
      expect(
        packageIdentityOf(
          '/p/.packages/file_picker_darwin-1.0.4/Sources/x/a.xcprivacy',
          locations,
          posix,
        ),
        'file_picker_darwin-1.0.4',
      );
    });

    test('target of a bundle and Xcode identifier', () {
      expect(
        targetOfBundle('GoogleUtilities_GoogleUtilities-Logger.bundle', [
          'GoogleUtilities-Logger',
          'Logger',
        ]),
        'GoogleUtilities-Logger',
      );
      expect(
        const SwiftPmResourceBundle(
          bundlePath: '/d/file_picker_darwin_file_picker_darwin.bundle',
          packageIdentity: 'file_picker_darwin-1.0.4',
          targetName: 'file_picker_darwin',
        ).bundleIdentifier,
        'file-picker-darwin-1.0.4.file-picker-darwin.resources',
      );
    });

    test('declared bundles swift build did not recreate', () {
      const privacy = SwiftPmBundleResource(
        source: '/c/SDWebImage/SDWebImage/Resources/PrivacyInfo.xcprivacy',
        relative: 'PrivacyInfo.xcprivacy',
      );
      const prefs = SwiftPmBundleResource(
        source: '/c/prefs/Resources/PrivacyInfo.xcprivacy',
        relative: 'PrivacyInfo.xcprivacy',
      );
      expect(
        missingSwiftPmResourceBundles(
          {
            'SDWebImage_SDWebImage.bundle': [privacy],
            'prefs_prefs.bundle': [prefs],
            // A test target the plugin build never compiled.
            'Pkg_PkgTests.bundle': [prefs],
            'Empty_Empty.bundle': [],
          },
          {'prefs_prefs.bundle'},
          ['SDWebImage', 'prefs', 'Empty'],
        ),
        ['SDWebImage_SDWebImage.bundle'],
      );
    });

    test('generated Info.plist', () {
      final xml = swiftPmResourceBundleInfoPlist(
        const SwiftPmResourceBundle(
          bundlePath: '/d/Firebase_FirebaseCore.bundle',
          packageIdentity: 'firebase-ios-sdk',
          targetName: 'FirebaseCore',
          minimumOsVersion: '15.0',
        ),
        deploymentTarget: '13.0',
        device: true,
        paths: posix,
      );
      expect(
        xml,
        contains('<string>firebase-ios-sdk.FirebaseCore.resources</string>'),
      );
      expect(xml, contains('<string>Firebase_FirebaseCore</string>'));
      expect(
        xml,
        contains('<key>MinimumOSVersion</key>\n\t<string>15.0</string>'),
      );
      expect(xml, contains('UIRequiredDeviceCapabilities'));
    });
  });
}
