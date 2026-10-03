import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/errors.dart';

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
    expect(
      await PluginDiscovery(LinuxHost().fileSystem).discover(tmp.path),
      isEmpty,
    );
  });

  test('returns [] when plugins.ios is empty', () async {
    writeDependenciesFile({
      'plugins': {'ios': <Object?>[]},
    });

    expect(
      await PluginDiscovery(LinuxHost().fileSystem).discover(tmp.path),
      isEmpty,
    );
  });

  test('returns [] when plugins.ios is missing', () async {
    writeDependenciesFile({'plugins': <String, Object?>{}});

    expect(
      await PluginDiscovery(LinuxHost().fileSystem).discover(tmp.path),
      isEmpty,
    );
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

      final plugins = await PluginDiscovery(
        LinuxHost().fileSystem,
      ).discover(tmp.path);

      expect(plugins, [
        IosPlugin(
          fileSystem: LinuxHost().fileSystem,
          name: 'plugin_a',
          packageRoot: pluginRoot,
        ),
      ]);
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

      final plugins = await PluginDiscovery(
        LinuxHost().fileSystem,
      ).discover(tmp.path);

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

    final plugins = await PluginDiscovery(
      LinuxHost().fileSystem,
    ).discover(tmp.path);

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

      final plugins = await PluginDiscovery(
        LinuxHost().fileSystem,
      ).discover(tmp.path);

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

    final plugins = await PluginDiscovery(
      LinuxHost().fileSystem,
    ).discover(tmp.path);

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

    final plugins = await PluginDiscovery(
      LinuxHost().fileSystem,
    ).discover(tmp.path);

    expect(plugins.single.packageRoot, pluginRoot);
  });

  test('malformed JSON throws FlutterBuildError', () {
    File(
      p.join(tmp.path, '.flutter-plugins-dependencies'),
    ).writeAsStringSync('{ not valid json');

    expect(
      () => PluginDiscovery(LinuxHost().fileSystem).discover(tmp.path),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  group('shared_darwin_source', () {
    /// Lays out a plugin whose native Apple sources live in a shared
    /// `darwin/` directory, the way `shared_preferences_foundation` and the
    /// other federated Apple implementation packages ship.
    String writeSharedDarwinPlugin(String name) {
      final pluginRoot = p.join(tmp.path, name);
      Directory(p.join(pluginRoot, 'darwin', name)).createSync(recursive: true);
      File(
        p.join(pluginRoot, 'darwin', name, 'Package.swift'),
      ).writeAsStringSync('');
      File(p.join(pluginRoot, 'darwin', '$name.podspec')).writeAsStringSync('');
      File(p.join(pluginRoot, 'pubspec.yaml')).writeAsStringSync('''
name: $name
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: ${name}Plugin
        sharedDarwinSource: true
''');
      return pluginRoot;
    }

    test('resolves native sources under darwin/ instead of ios/', () async {
      final pluginRoot = writeSharedDarwinPlugin('shared_prefs_foundation');

      writeDependenciesFile({
        'plugins': {
          'ios': [
            {
              'name': 'shared_prefs_foundation',
              'path': pluginRoot,
              'shared_darwin_source': true,
            },
          ],
        },
      });

      final plugin = (await PluginDiscovery(
        LinuxHost().fileSystem,
      ).discover(tmp.path)).single;

      expect(plugin.sharedDarwinSource, isTrue);
      expect(plugin.platformDirectoryName, 'darwin');
      expect(
        plugin.swiftPackageDir,
        p.join(pluginRoot, 'darwin', 'shared_prefs_foundation'),
      );
      expect(
        plugin.podspecPath,
        p.join(pluginRoot, 'darwin', 'shared_prefs_foundation.podspec'),
      );
      // The regression: these were both false, so the plugin was dropped from
      // the build with no warning and its channels hung at runtime.
      expect(plugin.usesSwiftPackageManager, isTrue);
      expect(plugin.usesCocoaPods, isTrue);
    });

    test('a darwin/ layout is not found without the flag', () async {
      final pluginRoot = writeSharedDarwinPlugin('unflagged_plugin');

      writeDependenciesFile({
        'plugins': {
          'ios': [
            {'name': 'unflagged_plugin', 'path': pluginRoot},
          ],
        },
      });

      final plugin = (await PluginDiscovery(
        LinuxHost().fileSystem,
      ).discover(tmp.path)).single;

      expect(plugin.sharedDarwinSource, isFalse);
      expect(plugin.platformDirectoryName, 'ios');
      expect(plugin.usesSwiftPackageManager, isFalse);
      // Still flagged as expecting native code, so the build warns rather
      // than dropping it silently.
      expect(plugin.declaresNativeIosCode, isTrue);
    });

    test('defaults to ios/ when the flag is absent or false', () async {
      final pluginRoot = p.join(tmp.path, 'regular_plugin');
      await Directory(
        p.join(pluginRoot, 'ios', 'regular_plugin'),
      ).create(recursive: true);
      File(
        p.join(pluginRoot, 'ios', 'regular_plugin', 'Package.swift'),
      ).writeAsStringSync('');

      writeDependenciesFile({
        'plugins': {
          'ios': [
            {
              'name': 'regular_plugin',
              'path': pluginRoot,
              'shared_darwin_source': false,
            },
          ],
        },
      });

      final plugin = (await PluginDiscovery(
        LinuxHost().fileSystem,
      ).discover(tmp.path)).single;

      expect(plugin.sharedDarwinSource, isFalse);
      expect(plugin.platformDirectoryName, 'ios');
      expect(plugin.usesSwiftPackageManager, isTrue);
    });

    test('equality and hashCode account for the flag', () {
      final shared = IosPlugin(
        fileSystem: LinuxHost().fileSystem,
        name: 'plugin',
        packageRoot: '/pkg',
        sharedDarwinSource: true,
      );
      final notShared = IosPlugin(
        fileSystem: LinuxHost().fileSystem,
        name: 'plugin',
        packageRoot: '/pkg',
      );

      expect(shared, isNot(notShared));
      expect(shared.hashCode, isNot(notShared.hashCode));
    });
  });

  group('declaresNativeIosCode', () {
    test('false for a plugin with no ios pluginClass', () async {
      final pluginRoot = p.join(tmp.path, 'dart_only');
      await Directory(pluginRoot).create(recursive: true);
      File(p.join(pluginRoot, 'pubspec.yaml')).writeAsStringSync('''
name: dart_only
flutter:
  plugin:
    platforms:
      ios:
        dartPluginClass: DartOnly
''');

      writeDependenciesFile({
        'plugins': {
          'ios': [
            {'name': 'dart_only', 'path': pluginRoot},
          ],
        },
      });

      expect(
        (await PluginDiscovery(
          LinuxHost().fileSystem,
        ).discover(tmp.path)).single.declaresNativeIosCode,
        isFalse,
      );
    });

    test('false when the pubspec is missing entirely', () async {
      final pluginRoot = p.join(tmp.path, 'no_pubspec');
      await Directory(pluginRoot).create(recursive: true);

      writeDependenciesFile({
        'plugins': {
          'ios': [
            {'name': 'no_pubspec', 'path': pluginRoot},
          ],
        },
      });

      expect(
        (await PluginDiscovery(
          LinuxHost().fileSystem,
        ).discover(tmp.path)).single.declaresNativeIosCode,
        isFalse,
      );
    });
  });
}
