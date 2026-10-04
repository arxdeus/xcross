import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:frontend_server_kit/frontend_server_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/mapped_frontend_file_system.dart';

/// Guards the file -> `package:` mapping that decides whether a breakpoint
/// binds. A `file:` URI is matched by the VM against the compile host's
/// absolute path; a `package:` URI is matched against the kernel's importUri.
/// Getting this wrong produces breakpoints that silently never resolve.
void main() {
  late Directory tmp;
  final host = MacOSHost();
  final loader = PackageUriLoader(
    fileSystem: host.fileSystem,
    paths: host.paths.context,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('frontend_server_pkg_uris-');
    await Directory(p.join(tmp.path, '.dart_tool')).create(recursive: true);
    await File(
      p.join(tmp.path, '.dart_tool', 'package_config.json'),
    ).writeAsString('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "my_app",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.6"
    }
  ]
}
''');
  });

  tearDown(() => tmp.delete(recursive: true));

  String configPath() => p.join(tmp.path, '.dart_tool', 'package_config.json');

  test(
    'mapped config resolves relative roots in the logical namespace',
    () async {
      final paths = p.Context(style: p.Style.posix, current: '/selected');
      final files = MappedFrontendFileSystem(tmp.path, paths);
      final root = files.logicalRoot;
      final mapped = PackageUriLoader(fileSystem: files, paths: paths);
      final config = '$root/.dart_tool/package_config.json';
      final uris = (await mapped.load(config))!;
      expect(
        uris.toCompilerUri('$root/lib/main.dart'),
        'package:my_app/main.dart',
      );
      expect(
        uris.toCompilerUri('$root/test/outside.dart'),
        '$root/test/outside.dart',
      );
      expect(
        uris.toCompilerUri('${tmp.path}/lib/main.dart'),
        '${tmp.path}/lib/main.dart',
      );
      expect(files.lookups, [config]);
      expect(await mapped.load('$root/missing.json'), isNull);
      await files.file('$root/bad.json').writeAsString('not json');
      expect(await mapped.load('$root/bad.json'), isNull);
      expect(Directory(root).existsSync(), isFalse);
    },
  );

  test('maps a lib/ file to its package: URI', () async {
    final uris = await loader.load(configPath());
    expect(uris, isNotNull);
    expect(
      uris!
          .toPackageUri(Uri.file(p.join(tmp.path, 'lib', 'main.dart')))
          .toString(),
      'package:my_app/main.dart',
    );
    expect(
      uris
          .toPackageUri(Uri.file(p.join(tmp.path, 'lib', 'src', 'a.dart')))
          .toString(),
      'package:my_app/src/a.dart',
    );
  });

  test('leaves files with no package equivalent alone', () async {
    final uris = (await loader.load(configPath()))!;
    // Outside lib/ — the VM will fall back to file-URI matching for these.
    final testFile = p.join(tmp.path, 'test', 'a_test.dart');
    expect(uris.toPackageUri(Uri.file(testFile)), isNull);
    expect(uris.toCompilerUri(testFile), testFile);
    // Already a package: URI, so not a file URI.
    expect(uris.toPackageUri(Uri.parse('package:my_app/main.dart')), isNull);
  });

  test('toCompilerUri returns the package: form when there is one', () async {
    final uris = (await loader.load(configPath()))!;
    expect(
      uris.toCompilerUri(p.join(tmp.path, 'lib', 'main.dart')),
      'package:my_app/main.dart',
    );
  });

  test(
    'returns null when the package config is missing or malformed',
    () async {
      expect(await loader.load(p.join(tmp.path, 'nope.json')), isNull);

      final bad = p.join(tmp.path, 'bad.json');
      await File(bad).writeAsString('not json at all');
      expect(await loader.load(bad), isNull);
    },
  );
}
