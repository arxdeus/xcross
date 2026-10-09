import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/config/project_settings.dart';
import 'package:xcross/src/shared/errors/errors.dart';

void main() {
  late Directory root;
  late ProjectSettings settings;
  setUp(() {
    root = Directory.systemTemp.createTempSync('project-settings-');
    settings = ProjectSettings(
      fileSystem: const IoFileSystem(),
      projectRoot: root.path,
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  File file(String name) => File(p.join(root.path, name));

  test('creates xcross_project.yaml when the project has no pubspec', () async {
    expect(settings.read('bundle_id'), isNull);
    await settings.write('bundle_id', 'original');
    expect(
      file('xcross_project.yaml').readAsStringSync(),
      'bundle_id: original\n',
    );
    expect(settings.read('bundle_id'), 'original');
  });

  test('adds an xcross section to pubspec.yaml, keeping the rest', () async {
    const pubspec =
        '# my app\nname: app\n\ndependencies:\n  flutter:\n    sdk: flutter\n';
    file('pubspec.yaml').writeAsStringSync(pubspec);
    await settings.write('bundle_id', 'prefixed');
    final written = file('pubspec.yaml').readAsStringSync();
    expect(written, startsWith(pubspec));
    expect(written, contains('xcross:\n  bundle_id: prefixed\n'));
    expect(file('xcross_project.yaml').existsSync(), isFalse);
    expect(settings.read('bundle_id'), 'prefixed');
  });

  test('updates an existing xcross section in place', () async {
    file('pubspec.yaml').writeAsStringSync(
      'name: app\nxcross:\n  other: kept # note\n  bundle_id: prefixed\n',
    );
    await settings.write('bundle_id', 'original');
    expect(
      file('pubspec.yaml').readAsStringSync(),
      'name: app\nxcross:\n  other: kept # note\n  bundle_id: original\n',
    );
  });

  test('xcross_project.yaml wins over pubspec.yaml', () {
    file(
      'pubspec.yaml',
    ).writeAsStringSync('name: app\nxcross:\n  bundle_id: original\n');
    file('xcross_project.yaml').writeAsStringSync('bundle_id: prefixed\n');
    expect(settings.read('bundle_id'), 'prefixed');
    expect(settings.path, file('xcross_project.yaml').path);
  });

  test('rejects a non-string value', () {
    file('xcross_project.yaml').writeAsStringSync('bundle_id: [1]\n');
    expect(() => settings.read('bundle_id'), throwsA(isA<XcrossError>()));
  });
}

final class IoFileSystem implements HostFileSystemInterface {
  const IoFileSystem();
  @override
  File file(String path) => File(path);
  @override
  Directory directory(String path) => Directory(path);
  @override
  Link link(String path) => Link(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
