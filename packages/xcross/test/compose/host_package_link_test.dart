@TestOn('!windows')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/swiftpm/host_package_link.dart';
import 'package:xcross/src/shared/compose/swiftpm/swift_package_model.dart';
import 'package:xcross/src/shared/swiftpm/package_types.dart';

import '../apple/support/native_test_file_system.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('xcross-hostpkg-'));
  tearDown(() => tmp.deleteSync(recursive: true));
  const files = NativeTestFileSystem();

  File write(String relative, String content) =>
      File(p.join(tmp.path, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  test('swiftcArguments: modules, every module map, binary frameworks, '
      'then the aggregate library', () {
    const link = HostPackageLink(
      productName: 'XcrossHostPackages',
      libraryPath: '/d/libXcrossHostPackages.dylib',
      modulesDir: '/d/Modules',
      moduleMapFiles: ['/c/a/module.modulemap', '/c/b/module.modulemap'],
      frameworkSearchPaths: ['/d'],
      build: SwiftPmBuildResult(
        libraryPath: '/d/libXcrossHostPackages.dylib',
        dylibPaths: [],
        modulesDir: '/d/Modules',
      ),
    );
    expect(link.swiftcArguments, [
      '-I',
      '/d/Modules',
      '-Xcc',
      '-fmodule-map-file=/c/a/module.modulemap',
      '-Xcc',
      '-fmodule-map-file=/c/b/module.modulemap',
      '-F',
      '/d',
      '-Xlinker',
      '/d/libXcrossHostPackages.dylib',
    ]);
  });

  test('swiftPmModuleMapFiles reads unique maps from debug.yaml', () {
    const yaml = '''
  "C.RealModule-arm64-apple-ios-debug.module":
    args: ["-Xcc","-fmodule-map-file=/s/checkouts/swift-numerics/Sources/_NumericsShims/include/module.modulemap","-I"]
  "C.ComplexModule":
    args: ["-Xcc","-fmodule-map-file=/s/checkouts/swift-numerics/Sources/_NumericsShims/include/module.modulemap"]
  "C.Other":
    args: ["-Xcc","-fmodule-map-file=/s/debug/Foo.build/module.modulemap"]
''';
    expect(swiftPmModuleMapFiles(yaml), [
      '/s/checkouts/swift-numerics/Sources/_NumericsShims/include/module.modulemap',
      '/s/debug/Foo.build/module.modulemap',
    ]);
  });

  test('swiftPmBuiltModules: swiftmodules, binary frameworks and the '
      'top-level modules of the maps SwiftPM used', () {
    final debug = p.join(tmp.path, 'debug');
    Directory(
      p.join(debug, 'Modules', 'Numerics.swiftmodule'),
    ).createSync(recursive: true);
    Directory(
      p.join(debug, 'Modules', 'RealModule.swiftmodule'),
    ).createSync(recursive: true);
    write('debug/Modules/RealModule.swiftdoc', '');
    Directory(p.join(debug, 'Tiny.framework')).createSync(recursive: true);
    final map = write(
      'checkouts/x/include/module.modulemap',
      'module _NumericsShims {\n  header "a.h"\n  module Sub { }\n}\n',
    );
    // Not passed to swiftc, so not importable: never scanned.
    write('checkouts/y/module.modulemap', 'module CppBenchmarks {}\n');
    expect(
      swiftPmBuiltModules(
        files: files,
        debugDirectory: debug,
        moduleMapFiles: [map.path],
      ),
      {'Numerics', 'RealModule', 'Tiny', '_NumericsShims'},
    );
  });

  test('declaredPackageModules: products, local package targets and '
      'targets of earlier checkouts', () {
    write('LocalPkg/Package.swift', '''
let package = Package(
  name: "LocalPkg",
  products: [.library(name: "LocalPkg", targets: ["LocalPkg"])],
  targets: [
    .target(name: "LocalPkg", dependencies: ["LocalCore"]),
    .target(name: "LocalCore"),
    .testTarget(name: "LocalPkgTests"),
  ]
)
''');
    write('checkouts/swift-numerics/Package.swift', '''
targets: [.target(name: "RealModule"), .binaryTarget(name: "Bin", path: "x")]
''');
    final local = LocalSwiftPackage(p.join(tmp.path, 'LocalPkg'));
    const remote = RemoteSwiftPackage(
      url: 'https://github.com/apple/swift-numerics',
      requirement: UpToNextMajorRequirement('1.0.0'),
    );
    final declared = HostSwiftPackages(
      packages: [local, remote],
      products: [
        SwiftPackageProductDependency(productName: 'LocalPkg', package: local),
        const SwiftPackageProductDependency(
          productName: 'Numerics',
          package: remote,
        ),
      ],
      packageResolvedPath: null,
      xcodeprojPath: null,
    );
    expect(declaredPackageModules(declared, files), {
      'LocalPkg',
      'LocalCore',
      'Numerics',
    });
    expect(
      declaredPackageModules(
        declared,
        files,
        checkoutsDir: p.join(tmp.path, 'checkouts'),
      ),
      {'LocalPkg', 'LocalCore', 'Numerics', 'RealModule', 'Bin'},
    );
  });
}
