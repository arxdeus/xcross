import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
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

    setUp(() {
      temp = Directory.systemTemp.createTempSync(
        'package_config_resolver_test-',
      );
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('finds a standalone project package config', () async {
      _writePackageConfig(temp.path);

      final result = await PackageConfigResolver.find(temp.path);

      expect(result, p.join(temp.path, '.dart_tool', 'package_config.json'));
    });

    test('finds a workspace package config in an ancestor', () async {
      final app = Directory(p.join(temp.path, 'apps', 'example'))
        ..createSync(recursive: true);
      _writePackageConfig(temp.path);

      final result = await PackageConfigResolver.find(app.path);

      expect(result, p.join(temp.path, '.dart_tool', 'package_config.json'));
    });

    test('prefers a local package config over an ancestor', () async {
      final app = Directory(p.join(temp.path, 'apps', 'example'))
        ..createSync(recursive: true);
      _writePackageConfig(temp.path);
      _writePackageConfig(app.path);

      final result = await PackageConfigResolver.find(app.path);

      expect(result, p.join(app.path, '.dart_tool', 'package_config.json'));
    });

    test('find returns null when no package config exists', () async {
      expect(await PackageConfigResolver.find(temp.path), isNull);
    });

    test('require reports the directory and recovery command', () async {
      await expectLater(
        PackageConfigResolver.require(temp.path),
        throwsA(
          isA<FlutterBuildError>()
              .having((error) => error.message, 'message', contains(temp.path))
              .having((error) => error.message, 'message', contains('pub get')),
        ),
      );
    });
  });

  test('all package config consumers use the shared resolver', () {
    final bundler = _readXcrossSource(
      'lib/src/flutter/build/flutter_debug_bundler.dart',
    );
    final packer = _readXcrossSource(
      'lib/src/flutter/build/flutter_packer.dart',
    );
    final hotReload = _readXcrossSource(
      'lib/src/flutter/build/hot_reload_setup.dart',
    );
    final dap = _readXcrossSource('lib/src/dap/xcross_dap.dart');

    expect(bundler, contains('PackageConfigResolver.require(projectRoot)'));
    expect(packer, contains('PackageConfigResolver.find(projectRoot)'));
    expect(hotReload, contains('PackageConfigResolver.require(projectRoot)'));
    expect(dap, contains('PackageConfigResolver.require(cwd)'));
  });
}
