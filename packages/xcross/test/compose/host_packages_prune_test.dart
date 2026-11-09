@TestOn('!windows')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/swiftpm/host_packages_builder.dart';
import 'package:xcross/src/shared/compose/swiftpm/swift_package_model.dart';

import '../apple/support/native_test_file_system.dart';
import '../log_fixture.dart';

void main() {
  late Directory tmp;
  late String packageDir;
  late String debugDir;
  late String localPkg;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xcross-hostpkg-prune-');
    packageDir = p.join(tmp.path, 'plugins', 'XcrossHostPackages');
    debugDir = p.join(tmp.path, 'scratch', 'arm64-apple-ios', 'debug');
    localPkg = p.join(tmp.path, 'LocalPkg');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String path, String content) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  HostSwiftPackages graph({bool local = false}) => HostSwiftPackages(
    packages: [if (local) LocalSwiftPackage(localPkg)],
    products: const [],
    packageResolvedPath: null,
    xcodeprojPath: null,
  );

  Future<void> prune(HostSwiftPackages packages) =>
      pruneStaleHostPackageProducts(
        files: const NativeTestFileSystem(),
        log: testLog(),
        packageDir: packageDir,
        packages: packages,
        debugDirectory: debugDir,
      );

  /// Simulates `swift build` leaving products in the debug directory.
  void build(String target) {
    write(p.join(debugDir, '${target}_$target.bundle', 'Info.plist'), 'x');
    write(p.join(debugDir, '$target.build', 'a.o'), 'o');
  }

  bool built(String target) =>
      Directory(p.join(debugDir, '${target}_$target.bundle')).existsSync() ||
      Directory(p.join(debugDir, '$target.build')).existsSync();

  test('keeps products while the package graph is unchanged', () async {
    write(p.join(packageDir, 'Package.swift'), 'alamofire');
    write(p.join(packageDir, 'Package.resolved'), 'pins v1');
    await prune(graph());
    build('Alamofire');
    await prune(graph());
    expect(built('Alamofire'), isTrue);
  });

  test('drops products of a package removed from the aggregate', () async {
    write(p.join(packageDir, 'Package.swift'), 'alamofire numerics');
    await prune(graph());
    build('Alamofire');
    write(p.join(packageDir, 'Package.swift'), 'numerics');
    await prune(graph());
    expect(built('Alamofire'), isFalse);
  });

  test('drops products when Package.resolved pins another version', () async {
    write(p.join(packageDir, 'Package.swift'), 'sdk');
    write(p.join(packageDir, 'Package.resolved'), 'pins v1');
    await prune(graph());
    build('SdkResources');
    write(p.join(packageDir, 'Package.resolved'), 'pins v2');
    await prune(graph());
    expect(built('SdkResources'), isFalse);
  });

  test('drops products when a local package manifest changes', () async {
    write(p.join(packageDir, 'Package.swift'), 'local');
    write(p.join(localPkg, 'Package.swift'), 'targets: A, Res');
    await prune(graph(local: true));
    build('Res');
    write(p.join(localPkg, 'Package.swift'), 'targets: A');
    await prune(graph(local: true));
    expect(built('Res'), isFalse);
  });

  test('drops products built before the graph was recorded', () async {
    write(p.join(packageDir, 'Package.swift'), 'numerics');
    build('Alamofire');
    await prune(graph());
    expect(built('Alamofire'), isFalse);
    expect(
      File(p.join(debugDir, hostPackagesGraphFingerprintFile)).existsSync(),
      isTrue,
    );
  });
}
