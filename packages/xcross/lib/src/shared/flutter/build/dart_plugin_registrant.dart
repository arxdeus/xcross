import 'package:cli_kit/shared/platform/platform_host.dart';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_plugins.dart';
import 'package:yaml/yaml.dart';

/// One plugin that registers itself from Dart rather than from native code.
@internal
@immutable
final class DartPluginRegistration {
  const DartPluginRegistration({
    required this.pluginName,
    required this.dartClass,
    required this.dartFileName,
  });

  /// Pub package the implementation lives in, e.g. `flutter_inappwebview_ios`.
  final String pluginName;

  /// The class exposing a static `registerWith()`, e.g.
  /// `IOSInAppWebViewPlatform`.
  final String dartClass;

  /// Library within the package's `lib/` that declares [dartClass]. Defaults to
  /// `<pluginName>.dart` when the pubspec doesn't say otherwise.
  final String dartFileName;

  /// `package:<pluginName>/<dartFileName>`.
  String get importUri => 'package:$pluginName/$dartFileName';

  @override
  bool operator ==(Object other) =>
      other is DartPluginRegistration &&
      other.pluginName == pluginName &&
      other.dartClass == dartClass &&
      other.dartFileName == dartFileName;

  @override
  int get hashCode => Object.hash(pluginName, dartClass, dartFileName);

  @override
  String toString() =>
      'DartPluginRegistration($pluginName, $dartClass, $dartFileName)';
}

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
/// Mirrors `generateMainDartWithPluginRegistrant` in flutter_tools'
/// `flutter_plugins.dart`.
@internal
final class DartPluginRegistrant {
  DartPluginRegistrant(this.fileSystem);
  final HostFileSystemInterface fileSystem;

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
  /// [entrypointUri] is the app's `main` as the compiler sees it; it is only
  /// recorded in a comment, since the generated file is passed as an extra
  /// `--source` rather than replacing the entrypoint.
  Future<String?> generate({
    required String projectRoot,
    required List<IosPlugin> plugins,
    String? entrypointUri,
  }) async {
    final registrations = resolveRegistrations(plugins);
    final file = fileSystem.file(pathFor(projectRoot));

    if (registrations.isEmpty) {
      if (file.existsSync()) await file.delete();
      return null;
    }

    await file.parent.create(recursive: true);
    await file.writeAsString(
      render(registrations, entrypointUri: entrypointUri),
    );
    return file.path;
  }

  /// The plugins in [plugins] that declare an iOS `dartPluginClass`, sorted by
  /// package name so the generated file is stable across builds.
  @visibleForTesting
  List<DartPluginRegistration> resolveRegistrations(List<IosPlugin> plugins) {
    final resolved = <DartPluginRegistration>[];
    for (final plugin in plugins) {
      final registration = _readRegistration(plugin);
      if (registration != null) resolved.add(registration);
    }
    resolved.sort((a, b) => a.pluginName.compareTo(b.pluginName));
    return resolved;
  }

  /// Reads `flutter.plugin.platforms.ios.dartPluginClass` (and the optional
  /// `dartFileName`) from [plugin]'s own pubspec.
  DartPluginRegistration? _readRegistration(IosPlugin plugin) {
    final file = fileSystem.file(p.join(plugin.packageRoot, 'pubspec.yaml'));
    if (!file.existsSync()) return null;

    final Object? pubspec;
    try {
      pubspec = loadYaml(file.readAsStringSync());
    } on Object {
      return null;
    }

    if (pubspec case {
      'flutter': {
        'plugin': {'platforms': {'ios': final Map<Object?, Object?> ios}},
      },
    }) {
      if (ios['dartPluginClass'] case final String dartClass) {
        return DartPluginRegistration(
          pluginName: plugin.name,
          dartClass: dartClass,
          dartFileName: ios['dartFileName'] as String? ?? '${plugin.name}.dart',
        );
      }
    }
    return null;
  }

  /// Renders the registrant source for [registrations].
  ///
  /// The shape is fixed by the VM, not by taste: the class must be named
  /// `_PluginRegistrant` with a static `register()`, and both it and the class
  /// need `@pragma('vm:entry-point')` or the entry point is tree-shaken away
  /// and registration silently never happens.
  @visibleForTesting
  static String render(
    List<DartPluginRegistration> registrations, {
    String? entrypointUri,
  }) {
    final buffer = StringBuffer()
      ..writeln('//')
      ..writeln('// Generated file. Do not edit.')
      ..writeln('// Generated by xcross.')
      ..writeln('//');
    if (entrypointUri != null) {
      buffer.writeln('// Entrypoint: $entrypointUri');
    }
    buffer
      ..writeln()
      ..writeln("import 'dart:io'; // flutter_ignore: dart_io_import.")
      ..writeln();

    for (final registration in registrations) {
      buffer.writeln(
        "import '${registration.importUri}' as ${registration.pluginName};",
      );
    }

    buffer
      ..writeln()
      ..writeln("@pragma('vm:entry-point')")
      ..writeln('class _PluginRegistrant {')
      ..writeln()
      ..writeln("  @pragma('vm:entry-point')")
      ..writeln('  static void register() {')
      ..writeln('    if (Platform.isIOS) {');

    for (final registration in registrations) {
      // A throwing plugin must not take the whole app down: flutter_tools
      // reports and continues, so one bad plugin degrades instead of
      // producing the same blank screen this file exists to prevent.
      buffer
        ..writeln('      try {')
        ..writeln(
          '        ${registration.pluginName}.${registration.dartClass}'
          '.registerWith();',
        )
        ..writeln('      } catch (err) {')
        ..writeln('        print(')
        ..writeln(
          "          '`${registration.pluginName}` threw an error: \$err. '",
        )
        ..writeln(
          "          'The app may not function as expected until you remove "
          "this plugin from pubspec.yaml'",
        )
        ..writeln('        );')
        ..writeln('      }');
    }

    buffer
      ..writeln('    }')
      ..writeln('  }')
      ..writeln('}');

    return buffer.toString();
  }
}
