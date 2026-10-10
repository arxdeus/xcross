import 'dart:convert';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:yaml/yaml.dart';

/// A `flutter.plugin.platforms` key as flutter_tools' `platform_plugins.dart`
/// describes it.
@internal
@immutable
final class PluginPlatformKey {
  const PluginPlatformKey(
    this.key, {
    required this.label,
    required this.platformGetter,
    this.desktop = false,
    this.sharedDarwinSource = false,
    this.packageWithPluginClass = false,
  });

  /// The pubspec key.
  final String key;

  /// The name flutter_tools uses in its `dartFileName` error.
  final String label;

  /// The `dart:io` `Platform` getter guarding this key in the registrant.
  final String platformGetter;

  /// Desktop keys only self-register a Dart implementation from Flutter 2.11.
  final bool desktop;

  /// Whether `sharedDarwinSource: true` alone makes the entry valid.
  final bool sharedDarwinSource;

  /// Whether `pluginClass` only counts alongside `package`.
  final bool packageWithPluginClass;

  /// The `validate(yaml)` of this key's `PluginPlatform`.
  bool validate(Map<Object?, Object?> config) =>
      (packageWithPluginClass
          ? config['package'] is String && config['pluginClass'] is String
          : config['pluginClass'] is String) ||
      config['dartPluginClass'] is String ||
      config['ffiPlugin'] == true ||
      (sharedDarwinSource && config['sharedDarwinSource'] == true) ||
      config['default_package'] is String;
}

/// The platform keys flutter_tools renders into the Dart plugin registrant, in
/// its template order.
@internal
const dartRegistrantPlatforms = [
  PluginPlatformKey(
    'android',
    label: 'Android',
    platformGetter: 'isAndroid',
    packageWithPluginClass: true,
  ),
  PluginPlatformKey(
    'ios',
    label: 'iOS',
    platformGetter: 'isIOS',
    sharedDarwinSource: true,
  ),
  PluginPlatformKey(
    'linux',
    label: 'Linux',
    platformGetter: 'isLinux',
    desktop: true,
  ),
  PluginPlatformKey(
    'macos',
    label: 'macOS',
    platformGetter: 'isMacOS',
    desktop: true,
    sharedDarwinSource: true,
  ),
  PluginPlatformKey(
    'windows',
    label: 'Windows',
    platformGetter: 'isWindows',
    desktop: true,
  ),
];

const _webKey = 'web';
const _legacyNativeKeys = ['android', 'ios'];

/// One platform's `dartPluginClass` and the library declaring it.
@internal
@immutable
final class DartPluginClass {
  const DartPluginClass({required this.dartClass, required this.dartFileName});

  final String dartClass;

  /// Library within the package's `lib/`; `<package>.dart` unless the pubspec
  /// names another.
  final String dartFileName;
}

/// A Flutter plugin package as flutter_tools' `Plugin` sees it, reduced to
/// what Dart plugin resolution reads.
@internal
@immutable
final class FlutterPluginPackage {
  const FlutterPluginPackage({
    required this.name,
    required this.root,
    required this.inlinePlatforms,
    required this.defaultPackages,
    required this.dartClasses,
    required this.isDirectDependency,
    this.implementsPackage,
    this.flutterConstraint,
  });

  final String name;
  final String root;

  /// `flutter.plugin.implements`: empty for a multi-platform plugin without
  /// one, null for the legacy format.
  final String? implementsPackage;

  /// Platforms with an inline (native or Dart) implementation.
  final Set<String> inlinePlatforms;

  /// `platforms.<platform>.default_package`.
  final Map<String, String> defaultPackages;

  /// `platforms.<platform>.dartPluginClass` with its `dartFileName`.
  final Map<String, DartPluginClass> dartClasses;

  /// `environment.flutter`.
  final VersionConstraint? flutterConstraint;

  /// Listed under the app's `dependencies`.
  final bool isDirectDependency;

  bool get _implementsOther =>
      implementsPackage != null && implementsPackage!.isNotEmpty;
}

/// A resolved Dart implementation for one platform.
@internal
@immutable
final class DartPluginResolution {
  const DartPluginResolution({
    required this.platform,
    required this.pluginName,
    required this.dartClass,
  });

  final String platform;
  final String pluginName;
  final DartPluginClass dartClass;
}

/// Lists the app's Flutter plugins like flutter_tools' `findPlugins`: every
/// package in the transitive closure of the app's `dependencies` and
/// `dev_dependencies` whose pubspec declares `flutter.plugin`.
@internal
final class FlutterPluginFinder {
  FlutterPluginFinder(this.fileSystem, this.paths);
  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  Future<List<FlutterPluginPackage>> find({
    required String projectRoot,
    required String packageConfigPath,
    required PackageConfig packageConfig,
  }) async {
    final manifest = _readYaml(paths.join(projectRoot, 'pubspec.yaml'));
    final rootName = manifest is Map<Object?, Object?>
        ? manifest['name'] as String? ?? ''
        : '';
    final appDependencies = {
      if (manifest case {'dependencies': final Map<Object?, Object?> deps})
        ...deps.keys.whereType<String>(),
    };
    final graph = PackageGraph.load(
      fileSystem,
      paths.join(paths.dirname(packageConfigPath), 'package_graph.json'),
    );

    final plugins = <FlutterPluginPackage>[];
    for (final name in _transitiveDependencies(
      rootName,
      graph ??
          PackageGraph.fromPubspecs(
            (package) => _readYaml(
              paths.join(
                paths.fromUri(packageConfig[package]!.root),
                'pubspec.yaml',
              ),
            ),
            packageConfig,
            rootName,
          ),
    )) {
      final String root;
      if (name == rootName) {
        root = projectRoot;
      } else {
        final package = packageConfig[name];
        if (package == null) {
          throw FlutterBuildError(
            'Could not locate package:$name. Try running `flutter pub get`',
          );
        }
        root = paths.fromUri(package.root);
      }
      final plugin = _pluginFromPackage(
        name,
        root,
        appDependencies: appDependencies,
      );
      if (plugin != null) plugins.add(plugin);
    }
    return plugins;
  }

  /// `computeTransitiveDependencies`, in the same visiting order.
  List<String> _transitiveDependencies(String rootName, PackageGraph graph) {
    final result = <String>[rootName];
    final seen = {rootName};
    final dependencies = graph.dependencies[rootName];
    final devDependencies = graph.devDependencies[rootName];
    if (dependencies == null || devDependencies == null) {
      throw FlutterBuildError(
        'Failed to parse ${graph.path}: '
        '${dependencies == null ? 'dependencies' : 'devDependencies'} '
        'for `$rootName` missing.\nTry running `flutter pub get`',
      );
    }
    final toVisit = [...dependencies, ...devDependencies];
    while (toVisit.isNotEmpty) {
      final current = toVisit.removeLast();
      if (!seen.add(current)) continue;
      final next = graph.dependencies[current];
      if (next == null) {
        throw FlutterBuildError(
          'Failed to parse ${graph.path}: dependencies for `$current` '
          'missing.\nTry running `flutter pub get`',
        );
      }
      toVisit.addAll(next);
      result.add(current);
    }
    return result;
  }

  Object? _readYaml(String path) {
    final file = fileSystem.file(path);
    if (!file.existsSync()) return null;
    try {
      return loadYaml(file.readAsStringSync());
    } on Object {
      return null;
    }
  }

  FlutterPluginPackage? _pluginFromPackage(
    String name,
    String root, {
    required Set<String> appDependencies,
  }) {
    final pubspec = _readYaml(paths.join(root, 'pubspec.yaml'));
    if (pubspec is! Map<Object?, Object?>) return null;
    final flutter = pubspec['flutter'];
    if (flutter is! Map<Object?, Object?> || !flutter.containsKey('plugin')) {
      return null;
    }
    final constraintText = switch (pubspec['environment']) {
      {'flutter': final String text} => text,
      _ => null,
    };
    final pluginYaml = flutter['plugin'];
    final yaml = pluginYaml is Map<Object?, Object?> ? pluginYaml : null;
    final errors = _validatePluginYaml(yaml);
    if (errors.isNotEmpty) {
      throw FlutterBuildError(
        'Invalid plugin specification $name.\n${errors.join('\n')}',
      );
    }
    final constraint = constraintText == null
        ? null
        : VersionConstraint.parse(constraintText);
    final isDirect = appDependencies.contains(name);
    if (yaml!['platforms'] case final Map<Object?, Object?> platforms) {
      return _multiPlatform(name, root, yaml, platforms, constraint, isDirect);
    }
    final pluginClass = yaml['pluginClass'] as String?;
    return FlutterPluginPackage(
      name: name,
      root: root,
      inlinePlatforms: {
        if (pluginClass != null) ...{
          if (yaml['androidPackage'] != null) _legacyNativeKeys.first,
          _legacyNativeKeys.last,
        },
      },
      defaultPackages: const {},
      dartClasses: const {},
      flutterConstraint: constraint,
      isDirectDependency: isDirect,
    );
  }

  FlutterPluginPackage _multiPlatform(
    String name,
    String root,
    Map<Object?, Object?> yaml,
    Map<Object?, Object?> platforms,
    VersionConstraint? constraint,
    bool isDirect,
  ) {
    final inline = <String>{};
    final web = platforms[_webKey];
    if (web is Map<Object?, Object?> && !web.containsKey(_defaultPackage)) {
      inline.add(_webKey);
      for (final field in ['pluginClass', 'fileName']) {
        if (web[field] is! String) {
          throw FlutterBuildError(
            'The plugin `$name` is missing the required field `$field` in '
            'pubspec.yaml',
          );
        }
      }
    }
    final defaults = <String, String>{};
    final dartClasses = <String, DartPluginClass>{};
    for (final platform in dartRegistrantPlatforms) {
      final config = platforms[platform.key];
      if (config is! Map<Object?, Object?>) continue;
      if (!config.containsKey(_defaultPackage)) {
        inline.add(platform.key);
        if (config[_dartPluginClass] == null && config[_dartFileName] != null) {
          throw FlutterBuildError(
            '"dartFileName" cannot be specified without "dartPluginClass" in '
            '${platform.label} platform of plugin "$name"',
          );
        }
      }
      if (config[_defaultPackage] case final String defaultPackage) {
        defaults[platform.key] = defaultPackage;
      }
      if (config[_dartPluginClass] case final String dartClass) {
        dartClasses[platform.key] = DartPluginClass(
          dartClass: dartClass,
          dartFileName: config[_dartFileName] as String? ?? '$name.dart',
        );
      }
    }
    return FlutterPluginPackage(
      name: name,
      root: root,
      implementsPackage: yaml['implements'] as String? ?? '',
      inlinePlatforms: inline,
      defaultPackages: defaults,
      dartClasses: dartClasses,
      flutterConstraint: constraint,
      isDirectDependency: isDirect,
    );
  }

  static List<String> _validatePluginYaml(Map<Object?, Object?>? yaml) {
    if (yaml == null) return ['Invalid "plugin" specification.'];
    final usesOld = _legacyKeys.any(yaml.containsKey);
    final usesNew = yaml.containsKey('platforms');
    const mixedFormats =
        'The flutter.plugin.platforms key cannot be used in combination with '
        'the old flutter.plugin.{androidPackage,iosPrefix,pluginClass} '
        'keys. See: https://flutter.dev/to/pubspec-plugin-platforms';
    const noFormat =
        'Cannot find the `flutter.plugin.platforms` key in the '
        '`pubspec.yaml` file. An instruction to format the '
        '`pubspec.yaml` can be found here: '
        'https://flutter.dev/to/pubspec-plugin-platforms';
    const platformsNotMap =
        'flutter.plugin.platforms should be a map with the platform name as '
        'the key';
    if (usesOld && usesNew) return const [mixedFormats];
    if (!usesOld && !usesNew) return const [noFormat];
    if (!usesNew) {
      return [
        for (final key in _legacyKeys)
          if (yaml[key] is! String?)
            'The "$key" must either be null or a string.',
      ];
    }
    final platforms = yaml['platforms'];
    if (platforms == null) return const ['Invalid "platforms" specification.'];
    if (platforms is! Map<Object?, Object?>) return const [platformsNotMap];
    return [
      for (final platform in dartRegistrantPlatforms)
        if (platforms.containsKey(platform.key) &&
            switch (platforms[platform.key]) {
              final Map<Object?, Object?> config =>
                !config.containsKey(_defaultPackage) &&
                    !platform.validate(config),
              _ => true,
            })
          'Invalid "${platform.key}" plugin specification.',
    ];
  }

  static const _legacyKeys = ['androidPackage', 'iosPrefix', 'pluginClass'];

  static const _dartPluginClass = 'dartPluginClass';
  static const _dartFileName = 'dartFileName';
  static const _defaultPackage = 'default_package';
}

/// `.dart_tool/package_graph.json`: each package's direct dependencies.
@internal
final class PackageGraph {
  PackageGraph(this.path, this.dependencies, this.devDependencies);

  /// The graph pub would write, rebuilt from each package's pubspec when
  /// `package_graph.json` is absent.
  factory PackageGraph.fromPubspecs(
    Object? Function(String package) pubspecOf,
    PackageConfig config,
    String rootName,
  ) {
    final dependencies = <String, List<String>>{};
    final devDependencies = <String, List<String>>{};
    for (final package in config.packages) {
      final pubspec = pubspecOf(package.name);
      List<String> keys(String section) => switch (pubspec) {
        final Map<Object?, Object?> map => switch (map[section]) {
          final Map<Object?, Object?> deps =>
            deps.keys.whereType<String>().toList()..sort(),
          _ => const [],
        },
        _ => const [],
      };
      dependencies[package.name] = keys('dependencies');
      devDependencies[package.name] = package.name == rootName
          ? keys('dev_dependencies')
          : const [];
    }
    return PackageGraph('package_graph.json', dependencies, devDependencies);
  }

  final String path;
  final Map<String, List<String>> dependencies;
  final Map<String, List<String>> devDependencies;

  static PackageGraph? load(HostFileSystemInterface fileSystem, String path) {
    final file = fileSystem.file(path);
    if (!file.existsSync()) return null;
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw FlutterBuildError(
        'Failed to parse $path: $e\nTry running `flutter pub get`',
      );
    }
    final dependencies = <String, List<String>>{};
    final devDependencies = <String, List<String>>{};
    if (json case {'packages': final List<Object?> packages}) {
      for (final package in packages) {
        if (package case {'name': final String name}) {
          dependencies[name] = _strings(package['dependencies']);
          devDependencies[name] = _strings(package['devDependencies']);
        }
      }
    }
    return PackageGraph(path, dependencies, devDependencies);
  }

  static List<String> _strings(Object? value) =>
      value is List ? value.whereType<String>().toList() : const [];
}

/// Ports flutter_tools' `resolvePlatformImplementation(plugins,
/// selectDartPluginsOnly: true)`.
@internal
final class DartPluginResolver {
  DartPluginResolver({this.onWarning});

  final void Function(String warning)? onWarning;

  /// Resolutions per platform, each sorted by plugin name.
  Map<String, List<DartPluginResolution>> resolve(
    List<FlutterPluginPackage> plugins,
  ) {
    final result = <String, List<DartPluginResolution>>{};
    final errors = <String>[];
    var hasPubspecError = false;
    var hasResolutionError = false;
    for (final key in dartRegistrantPlatforms) {
      final platform = key.key;
      final (resolved, pubspec, resolution) = _resolveByPlatform(
        plugins,
        platform,
        desktop: key.desktop,
      );
      errors
        ..addAll(pubspec)
        ..addAll(resolution);
      if (pubspec.isNotEmpty) {
        hasPubspecError = true;
      } else if (resolution.isNotEmpty) {
        hasResolutionError = true;
      } else {
        result[platform] = [
          for (final plugin in resolved)
            DartPluginResolution(
              platform: platform,
              pluginName: plugin.name,
              dartClass: plugin.dartClasses[platform]!,
            ),
        ];
      }
    }
    if (hasPubspecError) {
      throw FlutterBuildError(
        '${errors.join()}Please resolve the plugin pubspec errors',
      );
    }
    if (hasResolutionError) {
      throw FlutterBuildError(
        '${errors.join()}'
        'Please resolve the plugin implementation selection errors',
      );
    }
    return result;
  }

  (List<FlutterPluginPackage>, List<String>, List<String>) _resolveByPlatform(
    List<FlutterPluginPackage> plugins,
    String platform, {
    required bool desktop,
  }) {
    final pubspecErrors = <String>[];
    final resolutionErrors = <String>[];
    final candidates = <String, List<FlutterPluginPackage>>{};
    final defaults = <String, FlutterPluginPackage>{};

    for (final plugin in plugins) {
      final error = _validatePlugin(plugin, platform);
      if (error != null) {
        pubspecErrors.add(error);
        continue;
      }
      final implemented = _getImplementedPlugin(plugin, platform, desktop);
      final defaultName = _getDefaultImplPlugin(plugin, platform, desktop);
      if (defaultName != null) {
        final defaultPackage = plugins
            .where((candidate) => candidate.name == defaultName)
            .firstOrNull;
        if (defaultPackage == null) {
          onWarning?.call(
            'Package ${plugin.name}:$platform references '
            '$defaultName:$platform as the default plugin, but the package '
            'does not exist, or is not a plugin package.\n'
            'Ask the maintainers of ${plugin.name} to either avoid referencing '
            'a default implementation via `platforms: $platform: '
            'default_package: $defaultName` or create a plugin named '
            '$defaultName.\n',
          );
        } else if (!defaultPackage.inlinePlatforms.contains(platform)) {
          onWarning?.call(
            'Package ${plugin.name}:$platform references '
            '$defaultName:$platform as the default plugin, but it does not '
            'provide an inline implementation.\n'
            'Ask the maintainers of ${plugin.name} to either avoid referencing '
            'a default implementation via `platforms: $platform: '
            'default_package: $defaultName` or add an inline implementation '
            'to $defaultName via `platforms: $platform:` `pluginClass` or '
            '`dartPluginClass`.\n',
          );
        } else if (_hasPluginInlineDartImpl(defaultPackage, platform)) {
          defaults[plugin.name] = defaultPackage;
        }
      }
      if (implemented != null) {
        candidates.putIfAbsent(implemented, () => []).add(plugin);
      }
    }

    final resolution = <String, FlutterPluginPackage>{};
    for (final MapEntry(key: name, value: options) in candidates.entries) {
      final (resolved, error) = _resolveImplementationOfPlugin(
        platform: platform,
        pluginName: name,
        candidates: options,
        defaultPackage: defaults[name],
      );
      if (error != null) {
        resolutionErrors.add(error);
      } else if (resolved != null) {
        resolution[name] = resolved;
      }
    }
    final resolved = resolution.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return (resolved, pubspecErrors, resolutionErrors);
  }

  static String? _validatePlugin(FlutterPluginPackage plugin, String platform) {
    final implementsPackage = plugin.implementsPackage;
    final defaultName = plugin.defaultPackages[platform];
    if (plugin.name == implementsPackage && plugin.name == defaultName) {
      return null;
    }
    if (defaultName == null) return null;
    if (implementsPackage != null && implementsPackage.isNotEmpty) {
      return 'Plugin ${plugin.name}:$platform provides an implementation for '
          '$implementsPackage and also references a default implementation '
          'for $defaultName, which is currently not supported. Ask the '
          'maintainers of ${plugin.name} to either remove the implementation '
          'via `implements: $implementsPackage` or avoid referencing a '
          'default implementation via `platforms: $platform: '
          'default_package: $defaultName`.\n';
    }
    if (_hasPluginInlineDartImpl(plugin, platform)) {
      return 'Plugin ${plugin.name}:$platform which provides an inline '
          'implementation cannot also reference a default implementation for '
          '$defaultName. Ask the maintainers of ${plugin.name} to either '
          'remove the implementation via `platforms: $platform: '
          'dartPluginClass` or avoid referencing a default implementation via '
          '`platforms: $platform: default_package: $defaultName`.\n';
    }
    return null;
  }

  static String? _getImplementedPlugin(
    FlutterPluginPackage plugin,
    String platform,
    bool desktop,
  ) {
    if (!_hasPluginInlineDartImpl(plugin, platform)) return null;
    if (plugin._implementsOther) return plugin.implementsPackage;
    if (_isEligibleDartSelfImpl(plugin, desktop)) return plugin.name;
    return null;
  }

  static String? _getDefaultImplPlugin(
    FlutterPluginPackage plugin,
    String platform,
    bool desktop,
  ) {
    final defaultName = plugin.defaultPackages[platform];
    if (defaultName != null) return defaultName;
    if (_hasPluginInlineDartImpl(plugin, platform) &&
        _isEligibleDartSelfImpl(plugin, desktop)) {
      return plugin.name;
    }
    return null;
  }

  static bool _isEligibleDartSelfImpl(
    FlutterPluginPackage plugin,
    bool desktop,
  ) {
    final constraint = plugin.flutterConstraint;
    final min = constraint is VersionRange ? constraint.min : null;
    return !desktop || (min != null && min >= Version(2, 11, 0));
  }

  static bool _hasPluginInlineDartImpl(
    FlutterPluginPackage plugin,
    String platform,
  ) => plugin.dartClasses.containsKey(platform);

  static (FlutterPluginPackage?, String?) _resolveImplementationOfPlugin({
    required String platform,
    required String pluginName,
    required List<FlutterPluginPackage> candidates,
    FlutterPluginPackage? defaultPackage,
  }) {
    if (candidates.length == 1) return (candidates.first, null);
    final direct = candidates.where((plugin) => plugin.isDirectDependency);
    if (direct.isNotEmpty) {
      if (direct.length == 1) return (direct.first, null);
      final implementing = direct.where((plugin) => plugin._implementsOther);
      final appFacing = direct.toSet()..removeAll(implementing);
      if (implementing.length == 1 && appFacing.length == 1) {
        return (implementing.first, null);
      }
      return (
        null,
        'Plugin $pluginName:$platform has conflicting direct dependency '
            'implementations:\n'
            '${direct.map((plugin) => '  ${plugin.name}\n').join()}'
            'To fix this issue, remove all but one of these dependencies from '
            'pubspec.yaml.\n',
      );
    }
    if (defaultPackage != null && candidates.contains(defaultPackage)) {
      return (defaultPackage, null);
    }
    if (candidates.length > 1) {
      return (
        null,
        'Plugin $pluginName:$platform has multiple possible implementations:\n'
            '${candidates.map((plugin) => '  ${plugin.name}\n').join()}'
            'To fix this issue, add one of these dependencies to '
            'pubspec.yaml.\n',
      );
    }
    return (null, null);
  }
}
