import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/swiftpm/host_packages_manifest.dart';
import 'package:xcross/src/shared/compose/swiftpm/host_swift_packages_reader.dart';
import 'package:xcross/src/shared/compose/swiftpm/swift_package_model.dart';
import 'package:xcross/src/shared/errors/errors.dart';

/// A realistic Xcode 16 project: an app target with every requirement kind,
/// a local package with and without `package`, a plugin product, plus a
/// unit-test target and a widget extension with their own products.
const _pbxproj = r'''
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXFileReference section */
		A0000000000000000000F001 /* iosApp.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = iosApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
		A0000000000000000000F002 /* LegacyKit */ = {isa = PBXFileReference; lastKnownFileType = wrapper; path = ../LegacyKit; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXNativeTarget section */
		A0000000000000000000T001 /* iosApp */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A0000000000000000000C001 /* Build configuration list for PBXNativeTarget "iosApp" */;
			buildPhases = (
			);
			dependencies = (
			);
			name = iosApp;
			packageProductDependencies = (
				A0000000000000000000D001 /* Alamofire */,
				A0000000000000000000D002 /* Collections */,
				A0000000000000000000D003 /* OrderedCollections */,
				A0000000000000000000D004 /* Nuke */,
				A0000000000000000000D005 /* Kingfisher */,
				A0000000000000000000D006 /* Lottie */,
				A0000000000000000000D007 /* SnapKit */,
				A0000000000000000000D008 /* SharedUI */,
				A0000000000000000000D009 /* LegacyKit */,
				A0000000000000000000D00A /* SwiftLintBuildToolPlugin */,
			);
			productName = iosApp;
			productReference = A0000000000000000000F001 /* iosApp.app */;
			productType = "com.apple.product-type.application";
		};
		A0000000000000000000T002 /* iosAppTests */ = {
			isa = PBXNativeTarget;
			name = iosAppTests;
			packageProductDependencies = (
				A0000000000000000000D101 /* Quick */,
			);
			productName = iosAppTests;
			productType = "com.apple.product-type.bundle.unit-test";
		};
		A0000000000000000000T003 /* Widget */ = {
			isa = PBXNativeTarget;
			name = Widget;
			packageProductDependencies = (
				A0000000000000000000D102 /* WidgetHelpers */,
			);
			productName = Widget;
			productType = "com.apple.product-type.app-extension";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		A0000000000000000000P001 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
			};
			compatibilityVersion = "Xcode 14.0";
			mainGroup = A0000000000000000000G001;
			packageReferences = (
				A0000000000000000000R001 /* XCRemoteSwiftPackageReference "Alamofire" */,
				A0000000000000000000R002 /* XCRemoteSwiftPackageReference "swift-collections" */,
				A0000000000000000000R003 /* XCRemoteSwiftPackageReference "Nuke" */,
				A0000000000000000000R004 /* XCRemoteSwiftPackageReference "Kingfisher" */,
				A0000000000000000000R005 /* XCRemoteSwiftPackageReference "lottie-spm" */,
				A0000000000000000000R006 /* XCRemoteSwiftPackageReference "SnapKit" */,
				A0000000000000000000R007 /* XCLocalSwiftPackageReference "../Packages/SharedUI" */,
				A0000000000000000000R008 /* XCRemoteSwiftPackageReference "Quick" */,
				A0000000000000000000R009 /* XCRemoteSwiftPackageReference "WidgetHelpers" */,
				A0000000000000000000R00A /* XCRemoteSwiftPackageReference "SwiftLintPlugins" */,
			);
			productRefGroup = A0000000000000000000G002 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				A0000000000000000000T001 /* iosApp */,
				A0000000000000000000T002 /* iosAppTests */,
				A0000000000000000000T003 /* Widget */,
			);
		};
/* End PBXProject section */

/* Begin XCLocalSwiftPackageReference section */
		A0000000000000000000R007 /* XCLocalSwiftPackageReference "../Packages/SharedUI" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ../Packages/SharedUI;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCRemoteSwiftPackageReference section */
		A0000000000000000000R001 /* XCRemoteSwiftPackageReference "Alamofire" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/Alamofire/Alamofire.git";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 5.9.1;
			};
		};
		A0000000000000000000R002 /* XCRemoteSwiftPackageReference "swift-collections" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/apple/swift-collections";
			requirement = {
				kind = exactVersion;
				version = 1.1.4;
			};
		};
		A0000000000000000000R003 /* XCRemoteSwiftPackageReference "Nuke" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/kean/Nuke";
			requirement = {
				kind = upToNextMinorVersion;
				minimumVersion = 12.8.0;
			};
		};
		A0000000000000000000R004 /* XCRemoteSwiftPackageReference "Kingfisher" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/onevcat/Kingfisher.git";
			requirement = {
				kind = versionRange;
				maximumVersion = 9.0.0;
				minimumVersion = 7.0.0;
			};
		};
		A0000000000000000000R005 /* XCRemoteSwiftPackageReference "lottie-spm" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/airbnb/lottie-spm.git";
			requirement = {
				branch = main;
				kind = branch;
			};
		};
		A0000000000000000000R006 /* XCRemoteSwiftPackageReference "SnapKit" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/SnapKit/SnapKit";
			requirement = {
				kind = revision;
				revision = 2842e6e84e82eb9a8dac0100ca90d9444b0307f4;
			};
		};
		A0000000000000000000R008 /* XCRemoteSwiftPackageReference "Quick" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/Quick/Quick";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 7.0.0;
			};
		};
		A0000000000000000000R009 /* XCRemoteSwiftPackageReference "WidgetHelpers" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://example.com/WidgetHelpers.git";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 1.0.0;
			};
		};
		A0000000000000000000R00A /* XCRemoteSwiftPackageReference "SwiftLintPlugins" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/SimplyDanny/SwiftLintPlugins";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 0.57.0;
			};
		};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		A0000000000000000000D001 /* Alamofire */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R001 /* XCRemoteSwiftPackageReference "Alamofire" */;
			productName = Alamofire;
		};
		A0000000000000000000D002 /* Collections */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R002 /* XCRemoteSwiftPackageReference "swift-collections" */;
			productName = Collections;
		};
		A0000000000000000000D003 /* OrderedCollections */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R002 /* XCRemoteSwiftPackageReference "swift-collections" */;
			productName = OrderedCollections;
		};
		A0000000000000000000D004 /* Nuke */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R003 /* XCRemoteSwiftPackageReference "Nuke" */;
			productName = Nuke;
		};
		A0000000000000000000D005 /* Kingfisher */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R004 /* XCRemoteSwiftPackageReference "Kingfisher" */;
			productName = Kingfisher;
		};
		A0000000000000000000D006 /* Lottie */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R005 /* XCRemoteSwiftPackageReference "lottie-spm" */;
			productName = Lottie;
		};
		A0000000000000000000D007 /* SnapKit */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R006 /* XCRemoteSwiftPackageReference "SnapKit" */;
			productName = SnapKit;
		};
		A0000000000000000000D008 /* SharedUI */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R007 /* XCLocalSwiftPackageReference "../Packages/SharedUI" */;
			productName = SharedUI;
		};
		A0000000000000000000D009 /* LegacyKit */ = {
			isa = XCSwiftPackageProductDependency;
			productName = LegacyKit;
		};
		A0000000000000000000D00A /* SwiftLintBuildToolPlugin */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R00A /* XCRemoteSwiftPackageReference "SwiftLintPlugins" */;
			productName = "plugin:SwiftLintBuildToolPlugin";
		};
		A0000000000000000000D101 /* Quick */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R008 /* XCRemoteSwiftPackageReference "Quick" */;
			productName = Quick;
		};
		A0000000000000000000D102 /* WidgetHelpers */ = {
			isa = XCSwiftPackageProductDependency;
			package = A0000000000000000000R009 /* XCRemoteSwiftPackageReference "WidgetHelpers" */;
			productName = WidgetHelpers;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = A0000000000000000000P001 /* Project object */;
}
''';

const _resolvedV2 = '''
{
  "pins" : [
    {
      "identity" : "alamofire",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/Alamofire/Alamofire.git",
      "state" : {
        "revision" : "e16d3481f5ed35f0472cb93350085853d754913f",
        "version" : "5.10.1"
      }
    }
  ],
  "version" : 2
}
''';

const _resolvedV3 = '''
{
  "originHash" : "0d6c3a8e2f4b1c9a7e5d3b1f9e7c5a3d1b9f7e5c3a1d9b7f5e3c1a9d7b5f3e1c",
  "pins" : [
    {
      "identity" : "alamofire",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/Alamofire/Alamofire.git",
      "state" : {
        "revision" : "e16d3481f5ed35f0472cb93350085853d754913f",
        "version" : "5.10.1"
      }
    }
  ],
  "version" : 3
}
''';

const _golden = '''
// swift-tools-version:5.9
// Generated by xcross. Do not edit.
import PackageDescription

let package = Package(
    name: "XcrossHostPackages",
    platforms: [.iOS("15.0")],
    products: [
        .library(name: "XcrossHostPackages", type: .dynamic, targets: ["XcrossHostPackages"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.9.1"),
        .package(url: "https://github.com/onevcat/Kingfisher.git", "7.0.0"..<"9.0.0"),
        .package(path: "/ROOT/LegacyKit"),
        .package(url: "https://github.com/airbnb/lottie-spm.git", branch: "main"),
        .package(url: "https://github.com/kean/Nuke", .upToNextMinor(from: "12.8.0")),
        .package(path: "/ROOT/Packages/SharedUI"),
        .package(url: "https://github.com/SnapKit/SnapKit", revision: "2842e6e84e82eb9a8dac0100ca90d9444b0307f4"),
        .package(url: "https://github.com/apple/swift-collections", exact: "1.1.4"),
    ],
    targets: [
        .target(
            name: "XcrossHostPackages",
            dependencies: [
                .product(name: "Alamofire", package: "alamofire"),
                .product(name: "Kingfisher", package: "kingfisher"),
                .product(name: "LegacyKit", package: "legacykit"),
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "Nuke", package: "nuke"),
                .product(name: "SharedUI", package: "sharedui"),
                .product(name: "SnapKit", package: "snapkit"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            path: "Sources/XcrossHostPackages"
        ),
    ]
)
''';

void main() {
  late Directory root;
  late String iosApp;
  final files = LinuxHost(architecture: 'x64').fileSystem;

  void file(String path, [String content = '']) {
    File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  HostSwiftPackages read() =>
      readHostSwiftPackages(files: files, paths: p.context, iosAppDir: iosApp);

  void standardProject() {
    file('iosApp/iosApp.xcodeproj/project.pbxproj', _pbxproj);
    file(
      'Packages/SharedUI/Package.swift',
      '.library(name: "SharedUI", targets: ["SharedUI"])',
    );
    file(
      'LegacyKit/Package.swift',
      'products: [\n  .library(\n    name: "LegacyKit",\n    targets: [])]',
    );
  }

  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('compose_spm_')
          .resolveSymbolicLinksSync(),
    );
    iosApp = p.join(root.path, 'iosApp');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('reads app-target products with every requirement kind', () {
    standardProject();
    final result = read();
    final r = root.path;
    expect(result.xcodeprojPath, p.join(iosApp, 'iosApp.xcodeproj'));
    expect(result.packageResolvedPath, isNull);
    expect(result.packages.map((x) => x.identity), [
      'alamofire',
      'kingfisher',
      'legacykit',
      'lottie-spm',
      'nuke',
      'sharedui',
      'snapkit',
      'swift-collections',
    ]);
    expect(
      result.packages,
      contains(LocalSwiftPackage('$r/Packages/SharedUI')),
    );
    expect(result.packages, contains(LocalSwiftPackage('$r/LegacyKit')));
    expect(
      result.packages,
      containsAll(const [
        RemoteSwiftPackage(
          url: 'https://github.com/Alamofire/Alamofire.git',
          requirement: UpToNextMajorRequirement('5.9.1'),
        ),
        RemoteSwiftPackage(
          url: 'https://github.com/apple/swift-collections',
          requirement: ExactVersionRequirement('1.1.4'),
        ),
        RemoteSwiftPackage(
          url: 'https://github.com/kean/Nuke',
          requirement: UpToNextMinorRequirement('12.8.0'),
        ),
        RemoteSwiftPackage(
          url: 'https://github.com/onevcat/Kingfisher.git',
          requirement: VersionRangeRequirement('7.0.0', '9.0.0'),
        ),
        RemoteSwiftPackage(
          url: 'https://github.com/airbnb/lottie-spm.git',
          requirement: BranchRequirement('main'),
        ),
        RemoteSwiftPackage(
          url: 'https://github.com/SnapKit/SnapKit',
          requirement: RevisionRequirement(
            '2842e6e84e82eb9a8dac0100ca90d9444b0307f4',
          ),
        ),
      ]),
    );
    final names = result.products.map((x) => x.productName).toList();
    expect(names, isNot(contains('Quick')));
    expect(names, isNot(contains('WidgetHelpers')));
    expect(names, isNot(contains('plugin:SwiftLintBuildToolPlugin')));
    expect(names, hasLength(9));
  });

  test('deployment target: highest of the app targets, project fallback, '
      'test targets ignored', () {
    String project({String? appTarget}) =>
        '''
{
  objects = {
    APP = {
      isa = PBXNativeTarget;
      ${appTarget == null ? '' : 'buildConfigurationList = APPCFG;'}
      packageProductDependencies = (PROD);
      productType = "com.apple.product-type.application";
    };
    TESTS = {
      isa = PBXNativeTarget;
      buildConfigurationList = TESTCFG;
      productType = "com.apple.product-type.bundle.unit-test";
    };
    APPCFG = {isa = XCConfigurationList; buildConfigurations = (APPDBG, APPREL);};
    APPDBG = {isa = XCBuildConfiguration; buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = 16.0;};};
    APPREL = {isa = XCBuildConfiguration; buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = $appTarget;};};
    TESTCFG = {isa = XCConfigurationList; buildConfigurations = (TESTDBG);};
    TESTDBG = {isa = XCBuildConfiguration; buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = 18.0;};};
    PROJCFG = {isa = XCConfigurationList; buildConfigurations = (PROJDBG);};
    PROJDBG = {isa = XCBuildConfiguration; buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = 15.4;};};
    PROD = {isa = XCSwiftPackageProductDependency; package = PKG; productName = Alamofire;};
    PKG = {
      isa = XCRemoteSwiftPackageReference;
      repositoryURL = "https://github.com/Alamofire/Alamofire.git";
      requirement = {kind = upToNextMajorVersion; minimumVersion = 5.9.0;};
    };
    ROOT = {
      isa = PBXProject;
      buildConfigurationList = PROJCFG;
      packageReferences = (PKG);
      targets = (APP, TESTS);
    };
  };
  rootObject = ROOT;
}
''';
    file('iosApp/iosApp.xcodeproj/project.pbxproj', project(appTarget: '16.4'));
    expect(read().deploymentTarget, '16.4');
    file('iosApp/iosApp.xcodeproj/project.pbxproj', project());
    expect(read().deploymentTarget, '15.4');
    expect(compareVersions('16.0', '15.10'), greaterThan(0));
    expect(compareVersions('15', '15.0'), 0);
  });

  test('golden Package.swift', () {
    standardProject();
    final manifest = generateHostPackagesManifest(
      packages: read(),
      deploymentTarget: '15.0',
    );
    expect(manifest.packageSwift.replaceAll(root.path, '/ROOT'), _golden);
    expect(manifest.sources.keys, [
      'Sources/XcrossHostPackages/XcrossHostPackages.swift',
    ]);
    expect(manifest.allFiles.keys.first, 'Package.swift');
  });

  test('custom product name and escaping', () {
    final manifest = generateHostPackagesManifest(
      packages: const HostSwiftPackages(
        packages: [LocalSwiftPackage(r'/tmp/we"ird\pkg')],
        products: [
          SwiftPackageProductDependency(
            productName: 'A',
            package: LocalSwiftPackage(r'/tmp/we"ird\pkg'),
          ),
        ],
        packageResolvedPath: null,
        xcodeprojPath: null,
      ),
      deploymentTarget: '16.0',
      productName: 'Host',
    );
    expect(
      manifest.packageSwift,
      contains(r'.package(path: "/tmp/we\"ird\\pkg")'),
    );
    expect(manifest.packageSwift, contains(r'package: "we\"ird\\pkg"'));
    expect(manifest.sources.keys.single, 'Sources/Host/Host.swift');
  });

  test('empty package list generates an empty dependency list', () {
    final manifest = generateHostPackagesManifest(
      packages: HostSwiftPackages.empty,
      deploymentTarget: '15.0',
    );
    expect(manifest.packageSwift, contains('dependencies: [],'));
  });

  test('no iosApp, no project, or no packages yields empty', () {
    expect(read().isEmpty, isTrue);
    file('iosApp/iosApp/ContentView.swift');
    expect(read(), same(HostSwiftPackages.empty));
    file(
      'iosApp/iosApp.xcodeproj/project.pbxproj',
      '{ objects = { P = { isa = PBXProject; targets = (); }; }; rootObject = P; }',
    );
    final result = read();
    expect(result.isEmpty, isTrue);
    expect(result.xcodeprojPath, p.join(iosApp, 'iosApp.xcodeproj'));
  });

  test('Package.resolved v2 inside the project workspace', () {
    standardProject();
    file(
      'iosApp/iosApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/'
      'Package.resolved',
      _resolvedV2,
    );
    expect(
      read().packageResolvedPath,
      p.join(
        iosApp,
        'iosApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/'
        'Package.resolved',
      ),
    );
  });

  test('Package.resolved v3 in a referencing workspace wins', () {
    standardProject();
    file(
      'iosApp/iosApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/'
      'Package.resolved',
      _resolvedV2,
    );
    file(
      'iosApp/Other.xcworkspace/contents.xcworkspacedata',
      '<Workspace><FileRef location="group:Unrelated.xcodeproj"/></Workspace>',
    );
    file(
      'iosApp/Other.xcworkspace/xcshareddata/swiftpm/Package.resolved',
      _resolvedV3,
    );
    file(
      'iosApp/iosApp.xcworkspace/contents.xcworkspacedata',
      '<Workspace><FileRef location="group:iosApp.xcodeproj"/></Workspace>',
    );
    file(
      'iosApp/iosApp.xcworkspace/xcshareddata/swiftpm/Package.resolved',
      _resolvedV3,
    );
    expect(
      read().packageResolvedPath,
      p.join(
        iosApp,
        'iosApp.xcworkspace/xcshareddata/swiftpm/Package.resolved',
      ),
    );
  });

  test('product without package and no declaring local package fails', () {
    file('iosApp/iosApp.xcodeproj/project.pbxproj', _pbxproj);
    file('Packages/SharedUI/Package.swift', '.library(name: "SharedUI")');
    expect(
      read,
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('"LegacyKit"'),
        ),
      ),
    );
  });

  test('product declared by several local packages is ambiguous', () {
    standardProject();
    file(
      'Packages/SharedUI/Package.swift',
      '.library(name: "SharedUI"), .library(name: "LegacyKit")',
    );
    expect(
      read,
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('several local packages'),
        ),
      ),
    );
  });

  test('several projects merge; conflicting references fail', () {
    standardProject();
    file('iosApp/Second.xcodeproj/project.pbxproj', '''
{ objects = {
  P = { isa = PBXProject; packageReferences = (R); targets = (T); };
  T = { isa = PBXNativeTarget; productType = "com.apple.product-type.application"; packageProductDependencies = (D); };
  R = { isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/pointfreeco/swift-tagged"; requirement = { kind = exactVersion; version = 0.10.0; }; };
  D = { isa = XCSwiftPackageProductDependency; package = R; productName = Tagged; };
}; rootObject = P; }
''');
    final merged = read();
    expect(merged.products.map((x) => x.productName), contains('Tagged'));
    expect(merged.xcodeprojPath, p.join(iosApp, 'Second.xcodeproj'));

    file('iosApp/Second.xcodeproj/project.pbxproj', '''
{ objects = {
  P = { isa = PBXProject; packageReferences = (R); targets = (T); };
  T = { isa = PBXNativeTarget; productType = "com.apple.product-type.application"; packageProductDependencies = (D); };
  R = { isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/Alamofire/Alamofire.git"; requirement = { kind = exactVersion; version = 5.0.0; }; };
  D = { isa = XCSwiftPackageProductDependency; package = R; productName = Alamofire; };
}; rootObject = P; }
''');
    expect(read, throwsA(isA<XcrossError>()));
  });

  test('package identity follows SwiftPM', () {
    expect(
      swiftPackageIdentityForUrl('https://github.com/A/Swift-Foo.git'),
      'swift-foo',
    );
    expect(swiftPackageIdentityForUrl('git@github.com:a/Bar.git'), 'bar');
    expect(swiftPackageIdentityForUrl('https://x.org/a/baz/'), 'baz');
    expect(const LocalSwiftPackage('/a/MyPkg').identity, 'mypkg');
  });

  test('declaredLibraryProducts', () {
    expect(
      declaredLibraryProducts('''
        .library(name: "A", targets: ["A"]),
        .library(
            name: "B",
            type: .dynamic,
            targets: ["B"]),
        .executable(name: "C", targets: ["C"]),
      '''),
      {'A', 'B'},
    );
  });
}
