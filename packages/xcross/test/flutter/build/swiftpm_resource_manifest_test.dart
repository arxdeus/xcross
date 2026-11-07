import 'dart:convert';
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

  test('a localization directory keeps the source casing', () async {
    final source = p.join(tmp.path, 'src', 'en_GB.lproj', 'G.strings');
    File(source)
      ..createSync(recursive: true)
      ..writeAsStringSync('source');
    // `swift build` lowercases the directory in the built bundle.
    final built = p.join(tmp.path, 'debug', 'G_G.bundle');
    File(p.join(built, 'en_gb.lproj', 'G.strings'))
      ..createSync(recursive: true)
      ..writeAsStringSync('built');
    File(p.join(built, 'other.txt')).writeAsStringSync('other');
    final app = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
    await copierFor().copyResourceBundles(
      [
        SwiftPmResourceBundle(
          bundlePath: built,
          resources: [
            SwiftPmBundleResource(
              source: source,
              relative: p.join('en_GB.lproj', 'G.strings'),
            ),
          ],
        ),
      ],
      app.path,
      infoPlist: (_, _) => 'info',
    );
    final bundle = Directory(p.join(app.path, 'G_G.bundle'));
    final names = bundle.listSync().map((e) => p.basename(e.path)).toSet();
    expect(names, {'en_GB.lproj', 'other.txt', 'Info.plist'});
    expect(
      File(p.join(bundle.path, 'en_GB.lproj', 'G.strings')).readAsStringSync(),
      'source',
    );
  });

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

    test('keeps the source casing of .lproj directories', () {
      // swift build lowercases localization directories in its outputs;
      // Xcode 26.6 ships GoogleSignIn_GoogleSignIn.bundle/en_GB.lproj.
      const manifest = '''
commands:
  "/s/G_G.bundle/en_gb.lproj/GoogleSignIn.strings":
    tool: copy-tool
    inputs: ["/src/G/Strings/en_GB.lproj/GoogleSignIn.strings"]
    outputs: ["/s/G_G.bundle/en_gb.lproj/GoogleSignIn.strings"]

  "/s/G_G.bundle/zh_tw.lproj":
    tool: copy-tool
    inputs: ["/src/G/zh_TW.lproj/"]
    outputs: ["/s/G_G.bundle/zh_tw.lproj/"]
''';
      expect(
        parseSwiftPmResourceCopies(manifest, p.Context(style: p.Style.posix)),
        {
          'G_G.bundle': [
            const SwiftPmBundleResource(
              source: '/src/G/Strings/en_GB.lproj/GoogleSignIn.strings',
              relative: 'en_GB.lproj/GoogleSignIn.strings',
            ),
            const SwiftPmBundleResource(
              source: '/src/G/zh_TW.lproj',
              relative: 'zh_TW.lproj',
            ),
          ],
        },
      );
      expect(
        resourceCoverage(p.Context(style: p.Style.posix), 'en_gb.lproj', {
          'en_GB.lproj/GoogleSignIn.strings',
        }),
        ResourceCoverage.holdsResource,
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

    test('package and target of a bundle from manifest names', () {
      const state = '''
{"object":{"dependencies":[
 {"packageRef":{"identity":"googleutilities","kind":"remoteSourceControl","location":"https://github.com/google/GoogleUtilities.git","name":"GoogleUtilities"},"subpath":"GoogleUtilities"},
 {"packageRef":{"identity":"googlesignin-ios","kind":"remoteSourceControl","location":"https://github.com/google/GoogleSignIn-iOS.git","name":"GoogleSignIn"},"subpath":"GoogleSignIn-iOS"},
 {"packageRef":{"identity":"purchases-ios-spm","kind":"remoteSourceControl","location":"https://github.com/RevenueCat/purchases-ios-spm","name":"RevenueCat"},"subpath":"purchases-ios-spm"},
 {"packageRef":{"identity":"legacy","kind":"remoteSourceControl","location":"https://e/legacy"},"subpath":"legacy"},
 {"packageRef":{"identity":"file_picker_darwin","kind":"fileSystem","location":"/x/file_picker_darwin","name":"file_picker_darwin"},"subpath":"file_picker_darwin"}
]}}''';
      final packages = parseSwiftPmPackageReferences(state, '/s', posix);
      expect(packages.map((package) => package.identity), [
        'googleutilities',
        'googlesignin-ios',
        'purchases-ios-spm',
        'file_picker_darwin',
      ]);
      expect(packages.first.directory, '/s/checkouts/GoogleUtilities');
      expect(packages.last.directory, '/x/file_picker_darwin');

      final logger = packageOfBundle(
        'GoogleUtilities_GoogleUtilities-Logger.bundle',
        packages,
      )!;
      expect(logger.package.identity, 'googleutilities');
      expect(logger.target, 'GoogleUtilities-Logger');
      expect(
        SwiftPmResourceBundle(
          bundlePath: '/d/GoogleUtilities_GoogleUtilities-Logger.bundle',
          packageIdentity: logger.package.identity,
          targetName: logger.target,
        ).bundleIdentifier,
        'googleutilities.GoogleUtilities-Logger.resources',
      );
      final signIn = packageOfBundle(
        'GoogleSignIn_GoogleSignIn.bundle',
        packages,
      )!;
      expect(signIn.package.identity, 'googlesignin-ios');
      expect(signIn.target, 'GoogleSignIn');
      final revenueCat = packageOfBundle(
        'RevenueCat_RevenueCat_CustomEntitlementComputation.bundle',
        packages,
      )!;
      expect(revenueCat.package.identity, 'purchases-ios-spm');
      expect(revenueCat.target, 'RevenueCat_CustomEntitlementComputation');
      expect(packageOfBundle('Unknown_Target.bundle', packages), isNull);
    });

    test('package identity of a source reached through ..', () {
      final locations = {'/s/checkouts/purchases-ios-spm': 'purchases-ios-spm'};
      expect(
        packageIdentityOf(
          '/s/checkouts/purchases-ios-spm/Sources/../Sources/'
          'PrivacyInfo.xcprivacy',
          locations,
          posix,
        ),
        'purchases-ios-spm',
      );
    });

    test('Flutter plugin identities carry the pub package version', () {
      expect(
        flutterPluginSwiftPmIdentities({
          'file_picker_darwin': 'file_picker_darwin-1.0.4',
          // Depended on by firebase_auth via "../firebase_core": flutter_tools
          // rewrites that path to the versioned basename too.
          'firebase_core': 'firebase_core-4.15.0',
          'webview_flutter_wkwebview': 'webview_flutter_wkwebview-3.26.1',
          // A path dependency keeps its directory name.
          'flutter_chrome_cast': 'flutter_chrome_cast',
          'forked': 'Other_Fork',
        }),
        {
          'file_picker_darwin': 'file_picker_darwin-1.0.4',
          'firebase_core': 'firebase_core-4.15.0',
          'webview_flutter_wkwebview': 'webview_flutter_wkwebview-3.26.1',
          'flutter_chrome_cast': 'flutter_chrome_cast',
          'forked': 'other_fork',
        },
      );
    });

    test('MinimumOSVersion from the declared iOS platform', () {
      expect(
        swiftPmPackageMinimumOsVersion(
          'platforms: [.macOS(.v10_12), .iOS(.v12), .tvOS(.v9)]',
        ),
        '12.0',
      );
      expect(
        swiftPmPackageMinimumOsVersion('platforms: [.iOS("14.0")]'),
        '14.0',
      );
      expect(
        swiftPmPackageMinimumOsVersion(
          'platforms: [.macOS(.v10_15), .watchOS("6.2"), .iOS(.v13)]',
        ),
        '13.0',
      );
      // SDWebImage declares iOS 9 and leveldb none: Xcode 26.6 writes 12.0.
      expect(swiftPmPackageMinimumOsVersion('platforms: [.iOS(.v9)]'), '12.0');
      expect(swiftPmPackageMinimumOsVersion('let package = Package()'), '12.0');
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
            // Compiled for the plan or a sibling product, never linked.
            'SDWebImage_SDWebImageMapKit.bundle': [privacy],
            // A test target the plugin build never compiled.
            'Pkg_PkgTests.bundle': [prefs],
            'Empty_Empty.bundle': [],
          },
          {'prefs_prefs.bundle'},
          ['SDWebImage', 'SDWebImageMapKit', 'prefs', 'Empty'],
          {'SDWebImage', 'prefs', 'Empty'},
        ),
        ['SDWebImage_SDWebImage.bundle'],
      );
    });

    test('targets linked into a dylib or framework', () {
      String link(String output, List<String> inputs) =>
          '  "C.$output":\n'
          '    tool: shell\n'
          '    inputs: ${jsonEncode(inputs)}\n'
          '    outputs: ${jsonEncode([output])}\n';
      final manifest =
          'commands:\n'
          '${link('/d/libFlutterPluginsGenerated.dylib', ['/d/FlutterPluginsGenerated.build/A.swift.o', '/d/SDWebImage.build/SDImageCache.m.o', '/d/swift-version.txt'])}'
          '${link('/d/Lib.framework/Lib', ['/d/Lib.build/Lib.swift.o'])}'
          // Compile only: the object is not linked.
          '  "C.SDWebImageMapKit.module":\n'
          '    tool: shell\n'
          '    inputs: ["/s/MKAnnotationView+WebCache.m"]\n'
          '    outputs: ["/d/SDWebImageMapKit.build/MKAnnotationView.m.o"]\n'
          // A static archive is not embedded on its own.
          '${link('/d/libStatic.a', ['/d/Static.build/S.swift.o'])}';
      expect(parseSwiftPmLinkedTargets(manifest, p.posix), {
        '/d/libFlutterPluginsGenerated.dylib': {
          'FlutterPluginsGenerated',
          'SDWebImage',
        },
        '/d/Lib.framework/Lib': {'Lib'},
      });
      expect(
        parseSwiftPmLinkedTargets(
          'commands:\n'
          '${link(r'C:\d\libP.dylib', [r'C:\d\Win.build\W.swift.o'])}',
          p.windows,
        ),
        {
          r'C:\d\libP.dylib': {'Win'},
        },
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

  test('reads the copy rules of one target', () {
    const manifest = '''
let package = Package(name: "Pkg", targets: [
  .target(name: "P", resources: [.process("Res"), .copy("Other.xib")]),
  // .target(name: "C", resources: [.copy("Commented.xib")]),
  .target(name: "C", resources: [.copy("Copied.xib"), .copy("Dir/X.xib")]),
])
''';
    expect(swiftPmTargetCopyRules(manifest, 'C'), ['Copied.xib', 'Dir/X.xib']);
    expect(swiftPmTargetCopyRules(manifest, 'P'), ['Other.xib']);
    final bundle = SwiftPmResourceBundle(
      bundlePath: 'Pkg_C.bundle',
      targetName: 'C',
      copyRules: swiftPmTargetCopyRules(manifest, 'C'),
    );
    final copy = p.join('pkg', 'Sources', 'C', 'Copied.xib');
    expect(
      bundle.isCopiedVerbatim(
        SwiftPmBundleResource(source: copy, relative: 'Copied.xib'),
        p.context,
      ),
      isTrue,
    );
    expect(
      bundle.isCopiedVerbatim(
        SwiftPmBundleResource(
          source: p.join('pkg', 'Sources', 'C', 'Res', 'Copied.xib'),
          relative: p.join('Res', 'Copied.xib'),
        ),
        p.context,
      ),
      isFalse,
    );
    expect(
      bundle.isCopiedVerbatim(
        SwiftPmBundleResource(
          source: p.join('pkg', 'Sources', 'C', 'Dir', 'X.xib'),
          relative: 'X.xib',
        ),
        p.context,
      ),
      isTrue,
    );
    expect(
      const SwiftPmResourceBundle(
        bundlePath: 'x',
        targetName: 'a-b',
      ).moduleName,
      'a_b',
    );
  });
}
