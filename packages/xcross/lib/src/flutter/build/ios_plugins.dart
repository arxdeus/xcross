import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:yaml/yaml.dart';

/// One Flutter plugin's iOS native-code location, as recorded in
/// `.flutter-plugins-dependencies`.
@immutable
final class IosPlugin {
  const IosPlugin({
    required this.name,
    required this.packageRoot,
    this.sharedDarwinSource = false,
  });

  /// Pub package name (also the Dart class prefix / SPM directory name).
  final String name;

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
  bool get usesSwiftPackageManager => File(swiftPackageManifest).existsSync();

  /// Whether this plugin ships a CocoaPods podspec (may be true alongside
  /// [usesSwiftPackageManager] for dual-published plugins).
  bool get usesCocoaPods => File(podspecPath).existsSync();

  /// `flutter.plugin.platforms.ios.pluginClass` read from this plugin's own
  /// `pubspec.yaml`, or null if absent — e.g. a pure-Dart/FFI-only plugin, or
  /// a federated facade package (`path_provider`) with no direct native
  /// implementation (those declare `default_package:` instead, which isn't
  /// resolved here; the implementation package, e.g.
  /// `path_provider_foundation`, is a separate entry with its own
  /// `pluginClass`).
  String? get pluginClassIos {
    final file = File(p.join(packageRoot, 'pubspec.yaml'));
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
  String? get pluginClassIosAvailability => pluginClassIosAvailabilityIn();

  /// Also inspect a staged package: downloaded binary targets may exist only
  /// there after SwiftPM artifact preparation.
  String? pluginClassIosAvailabilityIn({String? stagedPackage}) {
    final pluginClass = pluginClassIos;
    if (pluginClass == null) return null;
    final packageDirectories = [
      swiftPackageDir,
      if (stagedPackage != null && !p.equals(stagedPackage, swiftPackageDir))
        stagedPackage,
    ];
    final declaration = RegExp('\\bclass\\s+${RegExp.escape(pluginClass)}\\b');
    final declarationPrefix = RegExp(
      r'^(?:(?:@[A-Za-z_]\w*(?:\([^)]*\))?|public|open|internal|private|'
      r'fileprivate|final|dynamic|nonisolated)\s+)*$',
    );
    final attributes = RegExp(
      r'^(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s*)+$',
      dotAll: true,
    );
    final availability = RegExp(r'@available\s*\(([^)]*)\)', dotAll: true);
    final shortIos = RegExp(r'(?:^|,)\s*iOS\s+(\d+(?:\.\d+){0,2})(?=\s*,|$)');
    final introducedIos = RegExp(
      r'(?:^|,)\s*iOS\s*,\s*introduced\s*:\s*(\d+(?:\.\d+){0,2})',
    );
    final objcDeclaration = RegExp(
      '@interface\\s+${RegExp.escape(pluginClass)}\\b',
    );
    final objcAvailability = RegExp(
      r'API_AVAILABLE\s*\([^;{}]*?\bios\s*\(\s*(\d+(?:\.\d+){0,2})\s*\)',
      dotAll: true,
    );
    String? requiredVersion;
    void consider(String version) {
      if (requiredVersion == null ||
          _compareIosVersions(version, requiredVersion!) > 0) {
        requiredVersion = version;
      }
    }

    Iterable<File> declarationFiles() sync* {
      for (final packageDirectory in packageDirectories) {
        final sources = Directory(p.join(packageDirectory, 'Sources'));
        if (sources.existsSync()) {
          yield* sources
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where(
                (file) => {'.swift', '.h'}.contains(p.extension(file.path)),
              );
        }
        final package = Directory(packageDirectory);
        if (!package.existsSync()) continue;
        for (final entity in package.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (!p.basename(entity.path).toLowerCase().endsWith('.xcframework')) {
            continue;
          }
          // SwiftPM can place downloaded artifacts behind .xa junctions.
          // Follow only the XCFramework root, not links inside the slice.
          final framework = Directory(entity.path);
          if (!framework.existsSync()) continue;
          for (final identifier in _iosDeviceSliceIdentifiers(framework)) {
            final slice = Directory(p.join(framework.path, identifier));
            if (!slice.existsSync()) continue;
            yield* slice
                .listSync(recursive: true, followLinks: false)
                .whereType<File>()
                .where(
                  (file) => {
                    '.swiftinterface',
                    '.h',
                  }.contains(p.extension(file.path.toLowerCase())),
                );
          }
        }
      }
    }

    for (final file in declarationFiles()) {
      // Preserve line boundaries while masking comments and string literals;
      // examples embedded in Swift multiline strings are not declarations.
      final source = _codeOutsideCommentsAndStrings(file.readAsStringSync());
      if (p.extension(file.path) == '.h') {
        var pendingAvailability = '';
        for (final rawLine in source.split(RegExp(r'\r?\n'))) {
          final line = rawLine.trim();
          if (line.isEmpty) continue;
          if (objcDeclaration.hasMatch(line)) {
            for (final annotation in objcAvailability.allMatches(
              '$pendingAvailability $line',
            )) {
              consider(annotation[1]!);
            }
            pendingAvailability = '';
          } else if (line.startsWith('API_AVAILABLE')) {
            pendingAvailability = '$pendingAvailability $line';
          } else {
            pendingAvailability = '';
          }
        }
        continue;
      }
      var pendingAttributes = '';
      for (final rawLine in source.split(RegExp(r'\r?\n'))) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        final match = declaration.firstMatch(line);
        if (match != null &&
            declarationPrefix.hasMatch(line.substring(0, match.start))) {
          final attached =
              '$pendingAttributes ${line.substring(0, match.start)}';
          if (pendingAttributes.isEmpty ||
              attributes.hasMatch(pendingAttributes)) {
            for (final annotation in availability.allMatches(attached)) {
              final body = annotation[1]!;
              final version =
                  shortIos.firstMatch(body)?[1] ??
                  introducedIos.firstMatch(body)?[1];
              if (version != null) consider(version);
            }
          }
          pendingAttributes = '';
          continue;
        }
        if (line.startsWith('@') ||
            (pendingAttributes.isNotEmpty &&
                !attributes.hasMatch(pendingAttributes))) {
          pendingAttributes = '$pendingAttributes $line'.trim();
          if (!pendingAttributes.startsWith('@') ||
              pendingAttributes.contains(';') ||
              pendingAttributes.contains('{') ||
              pendingAttributes.contains('}')) {
            pendingAttributes = '';
          }
        } else {
          // An intervening declaration owns any attributes above it.
          pendingAttributes = '';
        }
      }
    }
    return requiredVersion;
  }

  static Iterable<String> _iosDeviceSliceIdentifiers(Directory framework) {
    final plist = File(p.join(framework.path, 'Info.plist'));
    if (!plist.existsSync()) return const [];
    try {
      final bytes = plist.readAsBytesSync();
      final value =
          bytes.length >= 8 && ascii.decode(bytes.sublist(0, 8)) == 'bplist00'
          ? PropertyListSerialization.propertyListWithData(
              ByteData.sublistView(bytes),
            )
          : PropertyListSerialization.propertyListWithString(
              utf8.decode(bytes),
            );
      if (value is! Map || value['AvailableLibraries'] is! List) {
        return const [];
      }
      return [
        for (final library in value['AvailableLibraries'] as List)
          if (library is Map &&
              library['SupportedPlatform'] == 'ios' &&
              library['SupportedPlatformVariant'] == null &&
              library['SupportedArchitectures'] is List &&
              (library['SupportedArchitectures'] as List).contains('arm64') &&
              library['LibraryIdentifier'] is String &&
              p.basename(library['LibraryIdentifier'] as String) ==
                  library['LibraryIdentifier'] &&
              p.isWithin(
                framework.path,
                p.join(framework.path, library['LibraryIdentifier'] as String),
              ))
            library['LibraryIdentifier'] as String,
      ];
    } on Object {
      return const [];
    }
  }

  static String _codeOutsideCommentsAndStrings(String source) {
    final result = StringBuffer();
    var index = 0;
    var blockDepth = 0;
    var lineComment = false;
    var stringDelimiter = 0; // 0: code, 1: quoted, 3: multiline quoted
    var escaped = false;

    void mask(int count) {
      for (var offset = 0; offset < count; offset++) {
        final character = source[index + offset];
        result.write(character == '\n' || character == '\r' ? character : ' ');
      }
      index += count;
    }

    while (index < source.length) {
      final character = source[index];
      if (lineComment) {
        if (character == '\n') lineComment = false;
        mask(1);
      } else if (blockDepth > 0) {
        if (source.startsWith('/*', index)) {
          blockDepth++;
          mask(2);
        } else if (source.startsWith('*/', index)) {
          blockDepth--;
          mask(2);
        } else {
          mask(1);
        }
      } else if (stringDelimiter > 0) {
        if (!escaped &&
            stringDelimiter == 3 &&
            source.startsWith('"""', index)) {
          stringDelimiter = 0;
          mask(3);
        } else if (!escaped && stringDelimiter == 1 && character == '"') {
          stringDelimiter = 0;
          mask(1);
        } else {
          if (character == r'\' && !escaped) {
            escaped = true;
          } else {
            escaped = false;
          }
          mask(1);
        }
      } else if (source.startsWith('//', index)) {
        lineComment = true;
        mask(2);
      } else if (source.startsWith('/*', index)) {
        blockDepth = 1;
        mask(2);
      } else if (source.startsWith('"""', index)) {
        stringDelimiter = 3;
        mask(3);
      } else if (character == '"') {
        stringDelimiter = 1;
        mask(1);
      } else {
        result.write(character);
        index++;
      }
    }
    return result.toString();
  }

  static int _compareIosVersions(String left, String right) {
    final a = left.split('.').map(int.parse).toList();
    final b = right.split('.').map(int.parse).toList();
    for (var index = 0; index < 3; index++) {
      final difference =
          (index < a.length ? a[index] : 0) - (index < b.length ? b[index] : 0);
      if (difference != 0) return difference;
    }
    return 0;
  }

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
abstract final class PluginDiscovery {
  /// Every iOS plugin listed in `<projectRoot>/.flutter-plugins-dependencies`.
  ///
  /// Returns an empty list (never throws) if the file is missing or has no
  /// `plugins.ios` entries — absence of the file just means no plugins were
  /// ever resolved (e.g. `flutter pub get` not yet run), not a build error;
  /// callers decide whether that's fatal.
  ///
  /// Throws [FlutterBuildError] only if the file exists but holds bad JSON.
  static Future<List<IosPlugin>> discover(String projectRoot) async {
    final file = File(p.join(projectRoot, '.flutter-plugins-dependencies'));
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
