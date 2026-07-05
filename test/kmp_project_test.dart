import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/build/kmp_project.dart';
import 'package:xcross/src/util/errors.dart';

/// Resolve path to an example directory relative to the repo root.
///
/// Works regardless of CWD by anchoring to [Directory.current] (which is the
/// repo root when `dart test` is invoked from the project directory) and
/// falling back to walking up from the script path.
String _examplePath(String name) {
  // dart test sets CWD to the package root.
  final fromCwd = p.join(Directory.current.path, 'examples', name);
  if (Directory(fromCwd).existsSync()) return fromCwd;

  // Fallback: walk up from the script location.
  var dir = p.dirname(Platform.script.toFilePath());
  for (var i = 0; i < 5; i++) {
    final candidate = p.join(dir, 'examples', name);
    if (Directory(candidate).existsSync()) return candidate;
    dir = p.dirname(dir);
  }
  return fromCwd; // Let the test fail with a clear path.
}

void main() {
  group('detectKmpFramework — example_kmp', () {
    late KmpFrameworkModule result;

    setUpAll(() {
      result = detectKmpFramework(_examplePath('example_kmp'));
    });

    test('module name is shared', () {
      expect(result.moduleName, equals('shared'));
    });

    test('baseName is Shared', () {
      expect(result.baseName, equals('Shared'));
    });

    test('entryKind is runnableApp', () {
      expect(result.entryKind, equals(KmpEntryKind.runnableApp));
    });

    test('entryClass is MainViewControllerKt', () {
      expect(result.entryClass, equals('MainViewControllerKt'));
    });

    test('entrySelector is MainViewController (verbatim Kotlin fun name)', () {
      expect(result.entrySelector, equals('MainViewController'));
    });

    test('modulePath exists on disk', () {
      expect(Directory(result.modulePath).existsSync(), isTrue);
    });
  });

  group('detectKmpFramework — example_cmp', () {
    late KmpFrameworkModule result;

    setUpAll(() {
      result = detectKmpFramework(_examplePath('example_cmp'));
    });

    test('module name is sharedLogic', () {
      expect(result.moduleName, equals('sharedLogic'));
    });

    test('baseName is SharedLogic', () {
      expect(result.baseName, equals('SharedLogic'));
    });

    test('entryKind is swiftApp (SwiftUI iosApp, no Kotlin UI entry)', () {
      expect(result.entryKind, equals(KmpEntryKind.swiftApp));
    });

    test('entryClass is null', () {
      expect(result.entryClass, isNull);
    });

    test('entrySelector is null', () {
      expect(result.entrySelector, isNull);
    });

    test('swiftSources include the iosApp Swift files', () {
      final names = (result.swiftSources ?? const [])
          .map((p) => p.split('/').last)
          .toSet();
      expect(names, containsAll(<String>['iOSApp.swift', 'ContentView.swift']));
    });

    test('swiftAppDir ends with iosApp/iosApp (contains @main file)', () {
      expect(result.swiftAppDir, isNotNull);
      expect(
        result.swiftAppDir,
        endsWith(p.join('iosApp', 'iosApp')),
      );
    });

    test('swiftSources does not include Preview Content paths', () {
      for (final src in result.swiftSources ?? <String>[]) {
        expect(
          src,
          isNot(contains('Preview Content')),
          reason: 'Preview Content/ files must be excluded from swiftSources',
        );
      }
    });

    test('swiftImports include SwiftUI and the framework', () {
      expect(result.swiftImports, containsAll(<String>['SwiftUI', 'SharedLogic']));
    });
  });

  group('detectKmpFramework — nested module :a:b', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('kmp_nested_test_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('nested include(:a:b) → moduleName a:b, leaf b, diskPath a/b', () {
      // Create settings.gradle.kts with a nested module reference.
      File(p.join(tmpDir.path, 'settings.gradle.kts'))
          .writeAsStringSync('include(":a:b")\n');

      // Create the nested module directory + build.gradle.kts.
      final moduleDir = Directory(p.join(tmpDir.path, 'a', 'b'))
        ..createSync(recursive: true);
      File(p.join(moduleDir.path, 'build.gradle.kts'))
          .writeAsStringSync(
        'iosArm64()\nbinaries.framework\nbaseName = "Lib"\n',
      );

      final result = detectKmpFramework(tmpDir.path);

      // moduleName is the gradle colon form (no path separators).
      expect(result.moduleName, equals('a:b'));
      // moduleLeaf is the leaf segment — used for init-scripts + klib dirs.
      expect(result.moduleLeaf, equals('b'));
      // baseName extracted from build.gradle.kts.
      expect(result.baseName, equals('Lib'));
      // modulePath resolves to the correct disk directory.
      expect(result.modulePath, equals(p.join(tmpDir.path, 'a', 'b')));
      expect(Directory(result.modulePath).existsSync(), isTrue);
    });
  });

  group('detectKmpFramework — negative cases', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('kmp_test_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('throws XcrossError for missing settings.gradle.kts', () {
      expect(
        () => detectKmpFramework(tmpDir.path),
        throwsA(isA<XcrossError>()),
      );
    });

    test('throws XcrossError when no iosArm64 module found', () {
      // settings.gradle.kts exists but module has no iosArm64
      File(p.join(tmpDir.path, 'settings.gradle.kts'))
          .writeAsStringSync('include(":myModule")\n');
      final moduleDir = Directory(p.join(tmpDir.path, 'myModule'))
        ..createSync();
      File(p.join(moduleDir.path, 'build.gradle.kts'))
          .writeAsStringSync('// no iosArm64 here\n');

      expect(
        () => detectKmpFramework(tmpDir.path),
        throwsA(isA<XcrossError>()),
      );
    });
  });
}
