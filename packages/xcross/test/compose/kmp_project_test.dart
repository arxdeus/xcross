import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/errors.dart';

void main() {
  group('KmpProject.detect', () {
    test('detects runnable shared module and Kotlin entry', () {
      final root = _fixture();
      _settings(root, 'include(":shared")');
      _framework(root, 'shared', baseName: 'Shared');
      _kotlinEntry(root, 'shared', file: 'MainViewController.kt');

      final project = KmpProject.detect(root.path);

      expect(project.moduleName, 'shared');
      expect(project.baseName, 'Shared');
      expect(project.entryKind, KmpEntryKind.runnableApp);
      expect(project.entryClass, 'MainViewControllerKt');
      expect(project.entrySelector, 'MainViewController');
    });

    test('detects nested included module disk path and leaf base name', () {
      final root = _fixture();
      _settings(root, 'include(":a:b")');
      _framework(root, p.join('a', 'b'));

      final project = KmpProject.detect(root.path);

      expect(project.moduleName, 'a:b');
      expect(project.modulePath, p.join(root.path, 'a', 'b'));
      expect(project.baseName, 'B');
    });

    test('parses Kotlin settings include call with multiple modules', () {
      final root = _fixture();
      _settings(root, 'include(":shared", ":other")');
      _framework(root, 'shared', baseName: 'Shared');
      _framework(root, 'other', baseName: 'Other');
      _swift(root, p.join('iosApp', 'App.swift'), 'import Shared');

      final project = KmpProject.detect(root.path);

      expect(project.moduleName, 'shared');
    });

    test('parses Groovy settings include statement with multiple modules', () {
      final root = _fixture();
      _settings(
        root,
        "include ':shared', ':other'",
        fileName: 'settings.gradle',
      );
      _framework(root, 'shared', baseName: 'Shared');
      _framework(root, 'other', baseName: 'Other');
      _swift(root, p.join('iosApp', 'App.swift'), 'import Other');

      final project = KmpProject.detect(root.path);

      expect(project.moduleName, 'other');
    });

    test('detects Swift @main app and excludes Preview Content sources', () {
      final root = _fixture();
      _settings(root, 'include(":shared")');
      _framework(root, 'shared', baseName: 'Shared');
      _swift(
        root,
        p.join('iosApp', 'App.swift'),
        'import SwiftUI\nimport Shared\n@main struct Demo: App { var body: some Scene { WindowGroup { Text("Hi") } } }',
      );
      _swift(
        root,
        p.join('iosApp', 'Preview Content', 'Ignored.swift'),
        'import Missing',
      );

      final project = KmpProject.detect(root.path);

      expect(project.entryKind, KmpEntryKind.swiftApp);
      expect(project.swiftAppDir, p.join(root.path, 'iosApp'));
      expect(project.swiftSources, [p.join(root.path, 'iosApp', 'App.swift')]);
      expect(project.swiftImports, {'SwiftUI', 'Shared'});
    });

    test('detects committed Compose smoke examples', () {
      final compose = KmpProject.detect(
        p.join(_repoRoot, 'examples', 'compose_app'),
      );
      final swift = KmpProject.detect(
        p.join(_repoRoot, 'examples', 'kmp_swift_app'),
      );

      expect(compose.moduleName, 'shared');
      expect(compose.baseName, 'ComposeApp');
      expect(compose.entryKind, KmpEntryKind.runnableApp);
      expect(compose.entryClass, 'MainViewControllerKt');
      expect(compose.appName, 'ComposeApp');
      expect(compose.bundleId, 'org.example.ComposeApp');
      expect(swift.moduleName, 'shared');
      expect(swift.baseName, 'Shared');
      expect(swift.entryKind, KmpEntryKind.swiftApp);
      expect(swift.swiftSources, [
        p.join(
          _repoRoot,
          'examples',
          'kmp_swift_app',
          'iosApp',
          'KmpSwiftApp',
          'KmpSwiftApp.swift',
        ),
      ]);
      expect(swift.appName, 'KmpSwiftApp');
      expect(swift.bundleId, 'org.example.KmpSwiftApp');
    });

    test('detects framework only module when no app entry exists', () {
      final root = _fixture();
      _settings(root, 'include(":shared")');
      _framework(root, 'shared');

      final project = KmpProject.detect(root.path);

      expect(project.entryKind, KmpEntryKind.frameworkOnly);
      expect(project.entryClass, isNull);
      expect(project.entrySelector, isNull);
    });

    test('throws when no iOS framework module exists', () {
      final root = _fixture();
      _settings(root, 'include(":shared")');
      Directory(p.join(root.path, 'shared')).createSync(recursive: true);
      File(
        p.join(root.path, 'shared', 'build.gradle.kts'),
      ).writeAsStringSync('kotlin { jvm() }');

      expect(() => KmpProject.detect(root.path), throwsA(isA<XcrossError>()));
    });

    test(
      'throws ambiguity error for two matching modules without Swift import',
      () {
        final root = _fixture();
        _settings(root, 'include(":shared")\ninclude(":other")');
        _framework(root, 'shared', baseName: 'Shared');
        _framework(root, 'other', baseName: 'Other');

        expect(
          () => KmpProject.detect(root.path),
          throwsA(
            isA<XcrossError>().having(
              (e) => e.message,
              'message',
              contains('multiple'),
            ),
          ),
        );
      },
    );

    test(
      'throws ambiguity error for conflicting imports across Swift files',
      () {
        final root = _fixture();
        _settings(root, 'include(":shared")\ninclude(":other")');
        _framework(root, 'shared', baseName: 'Shared');
        _framework(root, 'other', baseName: 'Other');
        _swift(
          root,
          p.join('iosApp', 'App.swift'),
          'import SwiftUI\nimport Shared',
        );
        _swift(root, p.join('iosApp', 'Feature.swift'), 'import Other');

        expect(
          () => KmpProject.detect(root.path),
          throwsA(
            isA<XcrossError>().having(
              (e) => e.message,
              'message',
              contains('multiple'),
            ),
          ),
        );
      },
    );

    test('ignores preview and test Swift imports when disambiguating', () {
      final root = _fixture();
      _settings(root, 'include(":shared")\ninclude(":other")');
      _framework(root, 'shared', baseName: 'Shared');
      _framework(root, 'other', baseName: 'Other');
      _swift(root, p.join('iosApp', 'App.swift'), 'import Shared');
      _swift(
        root,
        p.join('iosApp', 'Preview Content', 'Preview.swift'),
        'import Other',
      );
      _swift(
        root,
        p.join('iosApp', 'AppTests', 'AppTests.swift'),
        'import Other',
      );

      final project = KmpProject.detect(root.path);

      expect(project.moduleName, 'shared');
    });

    test('resolves identity from explicit options before xcconfig', () {
      final root = _fixture();
      _settings(root, 'include(":shared")');
      _framework(root, 'shared');
      _xcconfig(
        root,
        productName: 'Config App',
        bundleId: 'org.example.config',
      );

      final project = KmpProject.detect(
        root.path,
        bundleId: 'org.example.cli',
        appName: 'CLI App',
      );

      expect(project.bundleId, 'org.example.cli');
      expect(project.appName, 'CLI App');
    });

    test('resolves identity from xcconfig before sanitized root defaults', () {
      final root = _fixture(name: 'My Root App!');
      _settings(root, 'include(":shared")');
      _framework(root, 'shared');
      _xcconfig(
        root,
        productName: 'Config App',
        bundleId: 'org.example.config',
      );

      final project = KmpProject.detect(root.path);

      expect(project.bundleId, 'org.example.config');
      expect(project.appName, 'Config App');
    });

    test('resolves identity from sanitized root directory defaults', () {
      final root = _fixture(name: 'My Root App!');
      _settings(root, 'include(":shared")');
      _framework(root, 'shared');

      final project = KmpProject.detect(root.path);

      expect(project.bundleId, 'com.example.myrootapp');
      expect(project.appName, 'My Root App');
    });
  });
}

final String _repoRoot = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:xcross/xcross.dart'))!,
).parent.parent.parent.parent.path;

Directory _fixture({String name = 'kmp_project'}) {
  final parent = Directory.systemTemp.createTempSync('xcross_fixture_');
  final root = Directory(p.join(parent.path, name))
    ..createSync(recursive: true);
  addTearDown(() => parent.deleteSync(recursive: true));
  return root;
}

void _settings(
  Directory root,
  String content, {
  String fileName = 'settings.gradle.kts',
}) {
  File(p.join(root.path, fileName)).writeAsStringSync(content);
}

void _framework(Directory root, String module, {String? baseName}) {
  final dir = Directory(p.join(root.path, module))..createSync(recursive: true);
  File(p.join(dir.path, 'build.gradle.kts')).writeAsStringSync('''
kotlin {
  iosArm64()
  binaries.framework {
    ${baseName == null ? '' : 'baseName = "$baseName"'}
  }
}
''');
}

void _kotlinEntry(Directory root, String module, {required String file}) {
  final dir = Directory(p.join(root.path, module, 'src', 'iosMain', 'kotlin'))
    ..createSync(recursive: true);
  File(p.join(dir.path, file)).writeAsStringSync('''
import androidx.compose.ui.window.ComposeUIViewController
fun MainViewController() = ComposeUIViewController { }
''');
}

void _swift(Directory root, String relativePath, String content) {
  final file = File(p.join(root.path, relativePath));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _xcconfig(
  Directory root, {
  required String productName,
  required String bundleId,
}) {
  final dir = Directory(p.join(root.path, 'iosApp', 'Configuration'))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'Config.xcconfig')).writeAsStringSync('''
PRODUCT_NAME = $productName
PRODUCT_BUNDLE_IDENTIFIER = $bundleId
''');
}
