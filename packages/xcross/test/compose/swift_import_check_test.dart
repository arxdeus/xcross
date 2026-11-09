import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/swift/swift_import.dart';
import 'package:xcross/src/shared/compose/swift/swift_import_check.dart';

void main() {
  late Directory root;
  late String bundle;
  late String sdk;

  setUp(() {
    root = Directory.systemTemp.createTempSync('swift_check_');
    bundle = p.join(root.path, 'bundle');
    sdk = p.join(bundle, 'sdk');
    Directory(
      p.join(sdk, 'System/Library/Frameworks/UIKit.framework/Modules'),
    ).createSync(recursive: true);
  });
  tearDown(() => root.deleteSync(recursive: true));

  KmpProject project(List<SwiftImport> imports) => KmpProject(
    root: '/proj',
    modulePath: '/proj/shared',
    moduleName: 'shared',
    baseName: 'Shared',
    entryKind: KmpEntryKind.swiftApp,
    bundleId: 'a.b',
    appName: 'A',
    swiftImports: imports,
  );

  List<UnresolvedSwiftImport> check(KmpProject project) =>
      unresolvedSwiftImports(
        project,
        swiftModuleIndexFor(
          files: LinuxHost(architecture: 'x64').fileSystem,
          sdkPath: sdk,
          darwinSdkBundle: bundle,
          platformSdkName: 'iphoneos',
          baseName: project.baseName,
        ),
      );

  test('reports missing modules sorted with first use', () {
    final proj = project([
      const SwiftImport('Zed', path: '/proj/iosApp/B.swift', line: 4),
      const SwiftImport('UIKit', path: '/proj/iosApp/B.swift', line: 1),
      const SwiftImport('Alpha', path: '/proj/iosApp/A.swift', line: 2),
      const SwiftImport('Alpha', path: '/proj/iosApp/C.swift', line: 9),
    ]);
    final result = check(proj);
    expect(result.map((u) => u.module), ['Alpha', 'Zed']);
    expect(result.first.firstUse.line, 2);
    expect(formatUnresolvedSwiftImports(proj, result), [
      '  - Alpha (imported at iosApp/A.swift:2)',
      '  - Zed (imported at iosApp/B.swift:4)',
    ]);
  });

  test('ignores conditional imports and the framework base name', () {
    final proj = project([
      const SwiftImport(
        'Ghost',
        path: '/proj/a.swift',
        line: 1,
        conditional: true,
      ),
      const SwiftImport('Shared', path: '/proj/a.swift', line: 2),
      const SwiftImport('UIKit', path: '/proj/a.swift', line: 3),
    ]);
    expect(check(proj), isEmpty);
  });
}
