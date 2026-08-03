import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross_flutter/src/build/ios_plugins.dart';
import 'package:xcross_flutter/src/errors.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_ios_plugins-');
  });

  tearDown(() => tmp.delete(recursive: true));

  void writeDependenciesFile(Map<String, Object?> json) {
    File(
      p.join(tmp.path, '.flutter-plugins-dependencies'),
    ).writeAsStringSync(jsonEncode(json));
  }

  test('returns [] when the dependencies file is missing', () async {
    expect(await PluginDiscovery.discover(tmp.path), isEmpty);
  });

  test('returns [] when plugins.ios is empty', () async {
    writeDependenciesFile({
      'plugins': {'ios': <Object?>[]},
    });

    expect(await PluginDiscovery.discover(tmp.path), isEmpty);
  });

  test('returns [] when plugins.ios is missing', () async {
    writeDependenciesFile({'plugins': <String, Object?>{}});

    expect(await PluginDiscovery.discover(tmp.path), isEmpty);
  });

  test(
    'podspec only: usesCocoaPods true, usesSwiftPackageManager false',
    () async {
      final pluginRoot = p.join(tmp.path, 'plugin_a');
      await Directory(p.join(pluginRoot, 'ios')).create(recursive: true);
      File(p.join(pluginRoot, 'ios', 'plugin_a.podspec')).writeAsStringSync('');

      writeDependenciesFile({
        'plugins': {
          'ios': [
            {
              'name': 'plugin_a',
              'path': pluginRoot,
              'dependencies': <String>[],
            },
          ],
        },
      });

      final plugins = await PluginDiscovery.discover(tmp.path);

      expect(plugins, [IosPlugin(name: 'plugin_a', packageRoot: pluginRoot)]);
      expect(plugins.single.usesCocoaPods, isTrue);
      expect(plugins.single.usesSwiftPackageManager, isFalse);
    },
  );

  test(
    'Package.swift only: usesSwiftPackageManager true, usesCocoaPods false',
    () async {
      final pluginRoot = p.join(tmp.path, 'plugin_b');
      await Directory(
        p.join(pluginRoot, 'ios', 'plugin_b'),
      ).create(recursive: true);
      File(
        p.join(pluginRoot, 'ios', 'plugin_b', 'Package.swift'),
      ).writeAsStringSync('');

      writeDependenciesFile({
        'plugins': {
          'ios': [
            {'name': 'plugin_b', 'path': pluginRoot},
          ],
        },
      });

      final plugins = await PluginDiscovery.discover(tmp.path);

      expect(plugins.single.usesSwiftPackageManager, isTrue);
      expect(plugins.single.usesCocoaPods, isFalse);
    },
  );

  test('both podspec and Package.swift present: both true', () async {
    final pluginRoot = p.join(tmp.path, 'plugin_c');
    await Directory(
      p.join(pluginRoot, 'ios', 'plugin_c'),
    ).create(recursive: true);
    File(
      p.join(pluginRoot, 'ios', 'plugin_c', 'Package.swift'),
    ).writeAsStringSync('');
    File(p.join(pluginRoot, 'ios', 'plugin_c.podspec')).writeAsStringSync('');

    writeDependenciesFile({
      'plugins': {
        'ios': [
          {'name': 'plugin_c', 'path': pluginRoot},
        ],
      },
    });

    final plugins = await PluginDiscovery.discover(tmp.path);

    expect(plugins.single.usesSwiftPackageManager, isTrue);
    expect(plugins.single.usesCocoaPods, isTrue);
  });

  test(
    'neither podspec nor Package.swift: both false, still returned',
    () async {
      final pluginRoot = p.join(tmp.path, 'plugin_d');
      await Directory(pluginRoot).create(recursive: true);

      writeDependenciesFile({
        'plugins': {
          'ios': [
            {'name': 'plugin_d', 'path': pluginRoot, 'native_build': false},
          ],
        },
      });

      final plugins = await PluginDiscovery.discover(tmp.path);

      expect(plugins, hasLength(1));
      expect(plugins.single.usesSwiftPackageManager, isFalse);
      expect(plugins.single.usesCocoaPods, isFalse);
    },
  );

  test('relative path is resolved against projectRoot', () async {
    final pluginRoot = p.join(tmp.path, 'local_plugin');
    await Directory(pluginRoot).create(recursive: true);

    writeDependenciesFile({
      'plugins': {
        'ios': [
          {'name': 'local_plugin', 'path': 'local_plugin'},
        ],
      },
    });

    final plugins = await PluginDiscovery.discover(tmp.path);

    expect(plugins.single.packageRoot, pluginRoot);
  });

  test('absolute path is used as-is', () async {
    final pluginRoot = p.join(tmp.path, 'abs_plugin');
    await Directory(pluginRoot).create(recursive: true);

    writeDependenciesFile({
      'plugins': {
        'ios': [
          {'name': 'abs_plugin', 'path': pluginRoot},
        ],
      },
    });

    final plugins = await PluginDiscovery.discover(tmp.path);

    expect(plugins.single.packageRoot, pluginRoot);
  });

  test('malformed JSON throws FlutterBuildError', () {
    File(
      p.join(tmp.path, '.flutter-plugins-dependencies'),
    ).writeAsStringSync('{ not valid json');

    expect(
      () => PluginDiscovery.discover(tmp.path),
      throwsA(isA<FlutterBuildError>()),
    );
  });
}
