import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/dart_plugin_resolution.dart';

/// Generates the `dart_plugin_registrant.dart` that federated plugins rely on
/// to install their Dart-side platform implementation.
///
/// Modern federated plugins split registration in two. The native half is the
/// `pluginClass` wired up by `GeneratedPluginRegistrant` (see
/// `ios_plugin_package.dart`); the Dart half is a `dartPluginClass` whose
/// static `registerWith()` assigns the package's `…Platform.instance`. Flutter
/// generates a registrant calling every such `registerWith()` and has the VM
/// run it before `main()`, via `--source` plus
/// `-Dflutter.dart_plugin_registrant`.
///
/// Skipping this step is not a compile error and not a crash: the app boots,
/// then the first use of an unregistered plugin throws
/// "a platform implementation has not been set" out of a top-level field
/// initializer or an `await` in `main()`, so `runApp` is never reached and the
/// device shows a black screen with nothing on the console.
///
/// The file is a kernel `--source`, so it is rendered byte-for-byte as
/// `generateMainDartWithPluginRegistrant` in flutter_tools'
/// `flutter_plugins.dart` renders it: any difference changes the AOT snapshot.
@internal
final class DartPluginRegistrant {
  DartPluginRegistrant(this.fileSystem, this.paths, {this.onWarning});
  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final void Function(String warning)? onWarning;

  /// Path of the generated registrant, matching the location flutter_tools
  /// uses so both tools stay interchangeable on one project.
  static String pathFor(String projectRoot) => p.join(
    projectRoot,
    '.dart_tool',
    'flutter_build',
    'dart_plugin_registrant.dart',
  );

  /// Writes the registrant for [projectRoot] and returns its path, or null
  /// when no plugin needs Dart-side registration (in which case any stale
  /// registrant is removed so a removed plugin doesn't linger).
  ///
  /// [entrypoint] is the app's main file; its language version becomes the
  /// registrant's.
  Future<String?> generate({
    required String projectRoot,
    required String packageConfigPath,
    required String entrypoint,
    required String flutterRoot,
  }) async {
    final packageConfig = await _loadPackageConfig(packageConfigPath);
    final plugins = await FlutterPluginFinder(fileSystem, paths).find(
      projectRoot: projectRoot,
      packageConfigPath: packageConfigPath,
      packageConfig: packageConfig,
    );
    final resolutions = DartPluginResolver(
      onWarning: onWarning,
    ).resolve(plugins);
    final path = pathFor(projectRoot);
    final file = fileSystem.file(path);

    if (resolutions.values.every((platform) => platform.isEmpty)) {
      if (file.existsSync()) await file.delete();
      return null;
    }

    final source = render(
      resolutions,
      languageVersion: languageVersionOf(
        entrypoint,
        packageConfig.packageOf(paths.toUri(paths.absolute(entrypoint))),
        flutterRoot,
      ),
    );
    if (file.existsSync() && file.readAsStringSync() == source) return path;
    await file.parent.create(recursive: true);
    await file.writeAsString(source);
    return path;
  }

  Future<PackageConfig> _loadPackageConfig(String path) => loadPackageConfigUri(
    paths.toUri(paths.absolute(path)),
    loader: (uri) async {
      if (!uri.isScheme('file')) return null;
      final file = fileSystem.file(paths.fromUri(uri));
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      return bytes;
    },
  );

  /// `determineLanguageVersion` from flutter_tools' `language_version.dart`:
  /// the file's own `// @dart = X.Y` comment, else [package]'s language
  /// version, else the Flutter SDK's Dart language version.
  @visibleForTesting
  String languageVersionOf(
    String entrypoint,
    Package? package,
    String flutterRoot,
  ) {
    final file = fileSystem.file(entrypoint);
    if (!file.existsSync()) return _currentLanguageVersion(flutterRoot);
    final List<String> lines;
    try {
      lines = file.readAsLinesSync();
    } on Object {
      return _currentLanguageVersion(flutterRoot);
    }
    var blockCommentDepth = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final starts = '/*'.allMatches(trimmed).length;
      final ends = '*/'.allMatches(trimmed).length;
      blockCommentDepth += starts - ends;
      if (blockCommentDepth != 0 || starts > 0 || ends > 0) continue;
      final match = _languageVersionComment.matchAsPrefix(trimmed);
      if (match != null) {
        final major = int.tryParse(match.group(1)!);
        final minor = int.tryParse(match.group(2)!);
        if (major == null || minor == null) break;
        return '$major.$minor';
      }
      if (_declarationEnd.matchAsPrefix(trimmed) != null) break;
    }
    if (package?.languageVersion case final version?) {
      return '${version.major}.${version.minor}';
    }
    return _currentLanguageVersion(flutterRoot);
  }

  String _currentLanguageVersion(String flutterRoot) {
    final text = fileSystem
        .file(paths.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'version'))
        .readAsStringSync();
    final match = RegExp(r'^(\d+)(\.(\d+))?').firstMatch(text)!;
    return '${int.parse(match.group(1)!)}.${int.parse(match.group(3) ?? '0')}';
  }

  static final _languageVersionComment = RegExp(
    r'\/\/\s*@dart\s*=\s*([0-9])\.([0-9]+)',
  );
  static final _declarationEnd = RegExp('(import)|(library)|(part)');

  /// Renders `_dartPluginRegistryForNonWebTemplate` for [resolutions], keyed
  /// by platform and sorted by plugin name within each.
  ///
  /// The shape is fixed by the VM, not by taste: the class must be named
  /// `_PluginRegistrant` with a static `register()`, and both it and the class
  /// need `@pragma('vm:entry-point')` or the entry point is tree-shaken away
  /// and registration silently never happens.
  @visibleForTesting
  static String render(
    Map<String, List<DartPluginResolution>> resolutions, {
    required String languageVersion,
  }) {
    final buffer = StringBuffer()
      ..write('''
//
// Generated file. Do not edit.
// This file is generated from template in file `flutter_tools/lib/src/flutter_plugins.dart`.
//

// @dart = $languageVersion

import 'dart:io'; // flutter_ignore: dart_io_import.
''');
    for (final platform in dartRegistrantPlatforms) {
      for (final resolution
          in resolutions[platform.key] ?? const <DartPluginResolution>[]) {
        buffer.write(
          "import 'package:${resolution.pluginName}/"
          "${resolution.dartClass.dartFileName}' as "
          '${resolution.pluginName};\n',
        );
      }
    }
    buffer.write('''

@pragma('vm:entry-point')
class _PluginRegistrant {

  @pragma('vm:entry-point')
  static void register() {
''');
    for (final (index, platform) in dartRegistrantPlatforms.indexed) {
      buffer.write(
        '${index == 0 ? '    if' : '    } else if'} '
        '(Platform.${platform.platformGetter}) {\n',
      );
      for (final resolution
          in resolutions[platform.key] ?? const <DartPluginResolution>[]) {
        final name = resolution.pluginName;
        buffer.write('''
      try {
        $name.${resolution.dartClass.dartClass}.registerWith();
      } catch (err) {
        print(
          '`$name` threw an error: \$err. '
          'The app may not function as expected until you remove this plugin from pubspec.yaml'
        );
      }

''');
      }
    }
    buffer.write('''
    }
  }
}
''');
    return buffer.toString();
  }
}
