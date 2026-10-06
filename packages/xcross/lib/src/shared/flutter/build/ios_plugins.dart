import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/plugins/plugin_class_availability_scanner.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:yaml/yaml.dart';

/// One Flutter plugin's iOS native-code location, as recorded in
/// `.flutter-plugins-dependencies`.
@internal
@immutable
final class IosPlugin {
  const IosPlugin({
    required this.name,
    required this.fileSystem,
    required this.packageRoot,
    this.sharedDarwinSource = false,
  });

  /// Pub package name (also the Dart class prefix / SPM directory name).
  final String name;
  final HostFileSystemInterface fileSystem;

  /// Absolute path to the plugin's pub package root (NOT the `ios/` subdir).
  final String packageRoot;

  /// Whether this plugin keeps its iOS and macOS native sources in one shared
  /// `darwin/` directory instead of separate `ios/` and `macos/` ones.
  ///
  /// Declared as `sharedDarwinSource: true` under `flutter.plugin.platforms.ios`
  /// in the plugin's own pubspec, and echoed into
  /// `.flutter-plugins-dependencies` as `shared_darwin_source`. Federated
  /// Apple implementation packages use it (`shared_preferences_foundation`,
  /// `file_selector_ios`, …), so missing it silently drops their native code:
  /// the app launches but every method channel call hangs forever.
  ///
  /// Mirrors `_darwinPluginDirectoryName` in flutter_tools' `plugins.dart`.
  final bool sharedDarwinSource;

  /// The package-root subdirectory holding this plugin's iOS native sources:
  /// `darwin` when [sharedDarwinSource], else `ios`.
  String get platformDirectoryName => sharedDarwinSource ? 'darwin' : 'ios';

  /// `<packageRoot>/<platformDir>/<name>/Package.swift` — the SPM manifest, if this
  /// plugin ships one.
  String get swiftPackageManifest => p.join(swiftPackageDir, 'Package.swift');

  /// Directory containing [swiftPackageManifest] (the SPM package root).
  String get swiftPackageDir =>
      p.join(packageRoot, platformDirectoryName, name);

  /// `<packageRoot>/<platformDir>/<name>.podspec` — the CocoaPods podspec, if any.
  String get podspecPath =>
      p.join(packageRoot, platformDirectoryName, '$name.podspec');

  /// Whether this plugin ships a Swift Package Manager manifest.
  bool get usesSwiftPackageManager =>
      fileSystem.file(swiftPackageManifest).existsSync();

  /// Whether this plugin ships a CocoaPods podspec (may be true alongside
  /// [usesSwiftPackageManager] for dual-published plugins).
  bool get usesCocoaPods => fileSystem.file(podspecPath).existsSync();

  /// `flutter.plugin.platforms.ios.pluginClass` read from this plugin's own
  /// `pubspec.yaml`, or null if absent — e.g. a pure-Dart/FFI-only plugin, or
  /// a federated facade package (`path_provider`) with no direct native
  /// implementation (those declare `default_package:` instead, which isn't
  /// resolved here; the implementation package, e.g.
  /// `path_provider_foundation`, is a separate entry with its own
  /// `pluginClass`).
  String? get pluginClassIos {
    final file = fileSystem.file(p.join(packageRoot, 'pubspec.yaml'));
    if (!file.existsSync()) return null;

    final Object? pubspec;
    try {
      pubspec = loadYaml(file.readAsStringSync());
    } on Object {
      return null;
    }

    if (pubspec case {
      'flutter': {
        'plugin': {
          'platforms': {'ios': {'pluginClass': final String pluginClass}},
        },
      },
    }) {
      return pluginClass;
    }
    return null;
  }

  /// An explicit iOS availability annotation attached to the plugin class,
  /// when one is present. The generated registrant uses it for
  /// a runtime guard; absent metadata must not be guessed from the package's
  /// minimum deployment target, which can be lower than the class's API.
  /// Also inspect a staged package: downloaded binary targets may exist only
  /// there after SwiftPM artifact preparation.
  String? pluginClassIosAvailabilityIn({
    required FlutterTargetBuildPolicy policy,
    String? stagedPackage,
  }) {
    final pluginClass = pluginClassIos;
    if (pluginClass == null) return null;
    final packageDirectories = [
      swiftPackageDir,
      if (stagedPackage != null && !p.equals(stagedPackage, swiftPackageDir))
        stagedPackage,
    ];
    final scanner = PluginClassAvailabilityScanner(pluginClass);
    for (final file in _availabilityDeclarationFiles(
      packageDirectories,
      policy,
    )) {
      scanner.scan(file);
    }
    return scanner.requiredVersion;
  }

  /// Swift sources and headers under each package's `Sources`, plus the
  /// interfaces and headers of every iOS device slice of any XCFramework in
  /// the package.
  Iterable<File> _availabilityDeclarationFiles(
    Iterable<String> packageDirectories,
    FlutterTargetBuildPolicy policy,
  ) sync* {
    for (final packageDirectory in packageDirectories) {
      final sources = fileSystem.directory(p.join(packageDirectory, 'Sources'));
      if (sources.existsSync()) {
        yield* _filesWithExtensions(sources, const {'.swift', '.h'});
      }
      final package = fileSystem.directory(packageDirectory);
      if (!package.existsSync()) continue;
      for (final entity in package.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (!p.basename(entity.path).toLowerCase().endsWith('.xcframework')) {
          continue;
        }
        yield* _xcframeworkDeclarationFiles(
          fileSystem.directory(entity.path),
          policy,
        );
      }
    }
  }

  Iterable<File> _xcframeworkDeclarationFiles(
    Directory framework,
    FlutterTargetBuildPolicy policy,
  ) sync* {
    // SwiftPM can place downloaded artifacts behind .xa junctions.
    // Follow only the XCFramework root, not links inside the slice.
    if (!framework.existsSync()) return;
    for (final identifier in _iosSliceIdentifiers(framework, policy)) {
      final slice = fileSystem.directory(p.join(framework.path, identifier));
      if (!slice.existsSync()) continue;
      yield* _filesWithExtensions(slice, const {
        '.swiftinterface',
        '.h',
      }, caseInsensitive: true);
    }
  }

  static Iterable<File> _filesWithExtensions(
    Directory directory,
    Set<String> extensions, {
    bool caseInsensitive = false,
  }) => directory
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where(
        (file) => extensions.contains(
          p.extension(caseInsensitive ? file.path.toLowerCase() : file.path),
        ),
      );

  /// Library identifiers of the XCFramework's arm64 iOS device slices, read
  /// from its `Info.plist`. Unreadable metadata yields no slices.
  Iterable<String> _iosSliceIdentifiers(
    Directory framework,
    FlutterTargetBuildPolicy policy,
  ) {
    final plist = fileSystem.file(p.join(framework.path, 'Info.plist'));
    if (!plist.existsSync()) return const [];
    try {
      final value = _decodePropertyList(plist.readAsBytesSync());
      if (value is! Map || value['AvailableLibraries'] is! List) {
        return const [];
      }
      return [
        for (final library in value['AvailableLibraries'] as List)
          if (library is Map && _isIosArm64Library(library, policy))
            if (library['LibraryIdentifier'] case final String identifier)
              if (_isDirectChildName(framework.path, identifier)) identifier,
      ];
    } on Object {
      return const [];
    }
  }

  static const _binaryPlistMagic = 'bplist00';

  static Object? _decodePropertyList(Uint8List bytes) {
    final isBinary =
        bytes.length >= _binaryPlistMagic.length &&
        ascii.decode(bytes.sublist(0, _binaryPlistMagic.length)) ==
            _binaryPlistMagic;
    return isBinary
        ? PropertyListSerialization.propertyListWithData(
            ByteData.sublistView(bytes),
          )
        : PropertyListSerialization.propertyListWithString(utf8.decode(bytes));
  }

  static bool _isIosArm64Library(
    Map<dynamic, dynamic> library,
    FlutterTargetBuildPolicy policy,
  ) =>
      library['SupportedPlatform'] == 'ios' &&
      library['SupportedPlatformVariant'] is String? &&
      policy.matchesLibraryVariant(
        library['SupportedPlatformVariant'] as String?,
      ) &&
      library['SupportedArchitectures'] is List &&
      (library['SupportedArchitectures'] as List).contains('arm64');

  /// Whether [name] is a single path segment naming a child of [parent].
  static bool _isDirectChildName(String parent, String name) =>
      p.basename(name) == name && p.isWithin(parent, p.join(parent, name));

  /// Whether this plugin's own pubspec declares a native iOS `pluginClass`,
  /// i.e. it is expected to contribute native code to the build.
  ///
  /// Used to tell a genuinely Dart-only plugin apart from one whose native
  /// sources simply were not found where they were looked for, so only the
  /// latter warrants a warning.
  bool get declaresNativeIosCode => pluginClassIos != null;

  @override
  bool operator ==(Object other) =>
      other is IosPlugin &&
      other.name == name &&
      other.packageRoot == packageRoot &&
      other.sharedDarwinSource == sharedDarwinSource;

  @override
  int get hashCode => Object.hash(name, packageRoot, sharedDarwinSource);

  @override
  String toString() =>
      'IosPlugin(name: $name, packageRoot: $packageRoot, '
      'sharedDarwinSource: $sharedDarwinSource)';
}

/// Discovers a Flutter project's iOS native plugin dependencies from
/// `.flutter-plugins-dependencies` (written by `flutter pub get`).
@internal
final class PluginDiscovery {
  PluginDiscovery(this.fileSystem);
  final HostFileSystemInterface fileSystem;

  /// Every iOS plugin listed in `<projectRoot>/.flutter-plugins-dependencies`.
  ///
  /// Returns an empty list (never throws) if the file is missing or has no
  /// `plugins.ios` entries — absence of the file just means no plugins were
  /// ever resolved (e.g. `flutter pub get` not yet run), not a build error;
  /// callers decide whether that's fatal.
  ///
  /// Throws [FlutterBuildError] only if the file exists but holds bad JSON.
  Future<List<IosPlugin>> discover(String projectRoot) async =>
      discoverSync(projectRoot);

  List<IosPlugin> discoverSync(String projectRoot) {
    final file = fileSystem.file(
      p.join(projectRoot, '.flutter-plugins-dependencies'),
    );
    if (!file.existsSync()) return const [];

    final Object? manifest;
    try {
      manifest = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw FlutterBuildError('${file.path}: invalid JSON: $e');
    }

    if (manifest case {'plugins': {'ios': final List<Object?> entries}}) {
      return [
        for (final entry in entries)
          if (entry case {'name': final String name, 'path': final String path})
            IosPlugin(
              fileSystem: fileSystem,
              name: name,
              packageRoot: _resolve(path, projectRoot),
              // Absent for the overwhelming majority of plugins; only the
              // shared-source Apple ones set it.
              sharedDarwinSource: entry['shared_darwin_source'] == true,
            ),
      ];
    }
    return const [];
  }

  static String _resolve(String path, String projectRoot) =>
      p.isAbsolute(path) ? path : p.join(projectRoot, path);
}
