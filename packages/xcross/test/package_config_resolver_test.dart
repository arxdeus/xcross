import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_hook_discovery.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/package_config_resolver.dart';

void _writePackageConfig(String directory) {
  final file = File(p.join(directory, '.dart_tool', 'package_config.json'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    jsonEncode(<String, Object>{'configVersion': 2, 'packages': <Object>[]}),
  );
}

String _readXcrossSource(String relativePath) {
  final library = File.fromUri(
    Isolate.resolvePackageUriSync(Uri.parse('package:xcross/xcross.dart'))!,
  );
  final packageRoot = library.parent.parent.path;
  return File(p.join(packageRoot, relativePath)).readAsStringSync();
}

void main() {
  group('PackageConfigResolver', () {
    late Directory temp;
    late PackageConfigResolver resolver;

    setUp(() {
      temp = Directory.systemTemp.createTempSync(
        'package_config_resolver_test-',
      );
      resolver = PackageConfigResolver(
        paths: p.Context(style: p.Style.posix),
        fileSystem: LinuxHost(
          currentDirectory: temp.path,
          temporaryDirectory: temp.path,
        ).fileSystem,
      );
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('finds a standalone project package config', () async {
      _writePackageConfig(temp.path);

      final result = await resolver.find(temp.path);

      expect(result, p.join(temp.path, '.dart_tool', 'package_config.json'));
    });

    test('finds a workspace package config in an ancestor', () async {
      final app = Directory(p.join(temp.path, 'apps', 'example'))
        ..createSync(recursive: true);
      _writePackageConfig(temp.path);

      final result = await resolver.find(app.path);

      expect(result, p.join(temp.path, '.dart_tool', 'package_config.json'));
    });

    test('prefers a local package config over an ancestor', () async {
      final app = Directory(p.join(temp.path, 'apps', 'example'))
        ..createSync(recursive: true);
      _writePackageConfig(temp.path);
      _writePackageConfig(app.path);

      final result = await resolver.find(app.path);

      expect(result, p.join(app.path, '.dart_tool', 'package_config.json'));
    });

    test('find returns null when no package config exists', () async {
      expect(await resolver.find(temp.path), isNull);
    });

    test(
      'legacy packages files remain excluded without a version override',
      () async {
        File(p.join(temp.path, '.packages')).writeAsStringSync('legacy:lib/');
        expect(await resolver.find(temp.path), isNull);
      },
    );

    test('require reports the directory and recovery command', () async {
      await expectLater(
        resolver.require(temp.path),
        throwsA(
          isA<FlutterBuildError>()
              .having((error) => error.message, 'message', contains(temp.path))
              .having((error) => error.message, 'message', contains('pub get')),
        ),
      );
    });
  });

  test(
    'remapped resolver and native hooks use selected files throughout',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'selected-package-config-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final fileSystem = PackageConfigMappedFileSystem(root);
      final app = fileSystem.directory('/workspace/apps/app')
        ..createSync(recursive: true);
      final config = fileSystem.file(
        '/workspace/.dart_tool/package_config.json',
      )..createSync(recursive: true);
      config.writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'selected',
              'rootUri': 'file:///selected%20dependency/',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final hook = fileSystem.file('/selected dependency/hook/build.dart')
        ..createSync(recursive: true);
      final resolver = PackageConfigResolver(
        fileSystem: fileSystem,
        paths: p.Context(style: p.Style.posix),
      );
      final discovery = NativeAssetsHookDiscovery(
        fileSystem: fileSystem,
        paths: p.Context(style: p.Style.posix),
        packageConfigs: resolver,
      );
      fileSystem.touched.clear();
      expect(
        await resolver.require('/workspace/apps/app'),
        '/workspace/.dart_tool/package_config.json',
      );
      expect(await discovery.hasBuildHooks('/workspace/apps/app'), isTrue);
      expect(fileSystem.touched, contains('/workspace/apps/app'));
      expect(
        fileSystem.touched,
        contains('/workspace/.dart_tool/package_config.json'),
      );
      expect(
        fileSystem.touched,
        contains('/selected dependency/hook/build.dart'),
      );
      hook.deleteSync();
      expect(await discovery.hasBuildHooks('/workspace/apps/app'), isFalse);
      expect(app.existsSync(), isTrue);
    },
  );

  test(
    'hook URI decoding follows injected Windows namespace on any host',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'windows-hook-namespace-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final fileSystem = PackageConfigMappedFileSystem(root);
      fileSystem.directory('/app').createSync();
      final config = fileSystem.file('/app/.dart_tool/package_config.json')
        ..createSync(recursive: true);
      config.writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'remote',
              'rootUri': 'https://example.invalid/dependency/',
            },
            {
              'name': 'selected',
              'rootUri': 'file:///C:/selected%20dependency/',
            },
          ],
        }),
      );
      fileSystem
          .file(r'C:\selected dependency\hook\build.dart')
          .createSync(recursive: true);
      final discovery = NativeAssetsHookDiscovery(
        fileSystem: fileSystem,
        paths: p.Context(style: p.Style.windows),
        packageConfigs: PackageConfigResolver(
          fileSystem: fileSystem,
          paths: p.Context(style: p.Style.posix),
        ),
      );
      fileSystem.touched.clear();
      expect(await discovery.hasBuildHooks('/app'), isTrue);
      expect(
        fileSystem.touched,
        contains(r'C:\selected dependency\hook\build.dart'),
      );
    },
  );

  for (final projectRoot in [r'C:\workspace', r'\\server\share\workspace']) {
    test(
      'selected Windows config and relative hooks preserve $projectRoot',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'selected-windows-config-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final paths = p.Context(style: p.Style.windows);
        final fileSystem = PackageConfigMappedFileSystem(root);
        fileSystem.directory(projectRoot).createSync(recursive: true);
        final configPath = paths.join(
          projectRoot,
          '.dart_tool',
          'package_config.json',
        );
        fileSystem.file(configPath)
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': 'selected',
                  'rootUri': '../dependency%20spaces/',
                  'packageUri': 'lib/',
                },
              ],
            }),
          );
        final hookPath = paths.join(
          projectRoot,
          'dependency spaces',
          'hook',
          'build.dart',
        );
        fileSystem.file(hookPath).createSync(recursive: true);
        final resolver = PackageConfigResolver(
          fileSystem: fileSystem,
          paths: paths,
        );
        final discovery = NativeAssetsHookDiscovery(
          fileSystem: fileSystem,
          paths: paths,
          packageConfigs: resolver,
        );
        fileSystem.touched.clear();
        expect(await resolver.require(projectRoot), configPath);
        expect(await discovery.hasBuildHooks(projectRoot), isTrue);
        expect(fileSystem.touched, contains(configPath));
        expect(fileSystem.touched, contains(hookPath));
        expect(
          fileSystem.touched,
          isNot(contains('/C:/workspace/.dart_tool/package_config.json')),
        );
      },
    );
  }

  test('resolver and hook discovery expose only neutral host contracts', () {
    for (final source in [
      _readXcrossSource('lib/src/package_config_resolver.dart'),
      _readXcrossSource(
        'lib/src/flutter/build/internal/native_assets_hook_discovery.dart',
      ),
    ]) {
      expect(source, contains('package:cli_kit/cli_kit_shared.dart'));
      expect(source, isNot(contains('package:cli_kit/cli_kit.dart')));
      expect(source, isNot(contains('Platform.')));
      expect(source, isNot(contains('File.fromUri(')));
    }
  });
}

final class PackageConfigMappedFileSystem implements HostFileSystemInterface {
  PackageConfigMappedFileSystem(this.root);
  final Directory root;
  final List<String> touched = [];
  String physical(String path) {
    if (path == root.path || p.isWithin(root.path, path)) return path;
    return p.join(
      root.path,
      path
          .replaceAll(r'\', '/')
          .replaceFirst(RegExp('^/+'), '')
          .replaceAll(':', ''),
    );
  }

  @override
  File file(String path) {
    touched.add(path);
    return File(physical(path));
  }

  @override
  Directory directory(String path) {
    touched.add(path);
    return Directory(physical(path));
  }

  @override
  Link link(String path) => Link(physical(path));
  @override
  void makeExecutable(String path) {}
  @override
  void setPermissions(String path, int mode) {}
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      link(destination).create(target);
}
