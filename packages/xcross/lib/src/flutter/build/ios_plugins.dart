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
    final scanner = _PluginClassAvailabilityScanner(pluginClass);
    for (final file in _availabilityDeclarationFiles(packageDirectories)) {
      scanner.scan(file);
    }
    return scanner.requiredVersion;
  }

  /// Swift sources and headers under each package's `Sources`, plus the
  /// interfaces and headers of every iOS device slice of any XCFramework in
  /// the package.
  static Iterable<File> _availabilityDeclarationFiles(
    Iterable<String> packageDirectories,
  ) sync* {
    for (final packageDirectory in packageDirectories) {
      final sources = Directory(p.join(packageDirectory, 'Sources'));
      if (sources.existsSync()) {
        yield* _filesWithExtensions(sources, const {'.swift', '.h'});
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
        yield* _xcframeworkDeviceDeclarationFiles(Directory(entity.path));
      }
    }
  }

  static Iterable<File> _xcframeworkDeviceDeclarationFiles(
    Directory framework,
  ) sync* {
    // SwiftPM can place downloaded artifacts behind .xa junctions.
    // Follow only the XCFramework root, not links inside the slice.
    if (!framework.existsSync()) return;
    for (final identifier in _iosDeviceSliceIdentifiers(framework)) {
      final slice = Directory(p.join(framework.path, identifier));
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
  static Iterable<String> _iosDeviceSliceIdentifiers(Directory framework) {
    final plist = File(p.join(framework.path, 'Info.plist'));
    if (!plist.existsSync()) return const [];
    try {
      final value = _decodePropertyList(plist.readAsBytesSync());
      if (value is! Map || value['AvailableLibraries'] is! List) {
        return const [];
      }
      return [
        for (final library in value['AvailableLibraries'] as List)
          if (library is Map && _isIosDeviceArm64Library(library))
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

  static bool _isIosDeviceArm64Library(Map<dynamic, dynamic> library) =>
      library['SupportedPlatform'] == 'ios' &&
      library['SupportedPlatformVariant'] == null &&
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

/// Collects the highest iOS availability version annotated directly on one
/// plugin class declaration across Swift and Objective-C sources.
final class _PluginClassAvailabilityScanner {
  _PluginClassAvailabilityScanner(String pluginClass)
    : _swiftDeclaration = RegExp(
        '\\bclass\\s+${RegExp.escape(pluginClass)}\\b',
      ),
      _objcDeclaration = RegExp(
        '@interface\\s+${RegExp.escape(pluginClass)}\\b',
      );

  static final _lineBreak = RegExp(r'\r?\n');
  static final _swiftDeclarationPrefix = RegExp(
    r'^(?:(?:@[A-Za-z_]\w*(?:\([^)]*\))?|public|open|internal|private|'
    r'fileprivate|final|dynamic|nonisolated)\s+)*$',
  );
  static final _swiftAttributes = RegExp(
    r'^(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s*)+$',
    dotAll: true,
  );
  static final _swiftAvailable = RegExp(
    r'@available\s*\(([^)]*)\)',
    dotAll: true,
  );
  static final _swiftShortIos = RegExp(
    r'(?:^|,)\s*iOS\s+(\d+(?:\.\d+){0,2})(?=\s*,|$)',
  );
  static final _swiftIntroducedIos = RegExp(
    r'(?:^|,)\s*iOS\s*,\s*introduced\s*:\s*(\d+(?:\.\d+){0,2})',
  );
  static final _objcAvailability = RegExp(
    r'API_AVAILABLE\s*\([^;{}]*?\bios\s*\(\s*(\d+(?:\.\d+){0,2})\s*\)',
    dotAll: true,
  );

  final RegExp _swiftDeclaration;
  final RegExp _objcDeclaration;

  /// The highest version seen so far, or null when none was annotated.
  String? requiredVersion;

  void scan(File file) {
    // Preserve line boundaries while masking comments and string literals;
    // examples embedded in Swift multiline strings are not declarations.
    final source = _codeOutsideCommentsAndStrings(file.readAsStringSync());
    final lines = source
        .split(_lineBreak)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    if (p.extension(file.path) == '.h') {
      _scanObjcHeader(lines);
    } else {
      _scanSwift(lines);
    }
  }

  void _consider(String version) {
    if (requiredVersion == null ||
        _compareIosVersions(version, requiredVersion!) > 0) {
      requiredVersion = version;
    }
  }

  /// `API_AVAILABLE(ios(X))` lines directly above, or on, `@interface Class`.
  void _scanObjcHeader(Iterable<String> lines) {
    var pendingAvailability = '';
    for (final line in lines) {
      if (_objcDeclaration.hasMatch(line)) {
        for (final annotation in _objcAvailability.allMatches(
          '$pendingAvailability $line',
        )) {
          _consider(annotation[1]!);
        }
        pendingAvailability = '';
      } else if (line.startsWith('API_AVAILABLE')) {
        pendingAvailability = '$pendingAvailability $line';
      } else {
        pendingAvailability = '';
      }
    }
  }

  /// `@available(iOS X, ...)` attributes attached to `class Class`, either
  /// inline or on the attribute-only lines immediately above it.
  void _scanSwift(Iterable<String> lines) {
    var pendingAttributes = '';
    for (final line in lines) {
      final match = _swiftDeclaration.firstMatch(line);
      if (match != null) {
        final prefix = line.substring(0, match.start);
        if (_swiftDeclarationPrefix.hasMatch(prefix)) {
          if (pendingAttributes.isEmpty ||
              _swiftAttributes.hasMatch(pendingAttributes)) {
            _considerSwiftAttributes('$pendingAttributes $prefix');
          }
          pendingAttributes = '';
          continue;
        }
      }
      pendingAttributes = _nextPendingAttributes(pendingAttributes, line);
    }
  }

  void _considerSwiftAttributes(String attached) {
    for (final annotation in _swiftAvailable.allMatches(attached)) {
      final body = annotation[1]!;
      final version =
          _swiftShortIos.firstMatch(body)?[1] ??
          _swiftIntroducedIos.firstMatch(body)?[1];
      if (version != null) _consider(version);
    }
  }

  /// Accumulate attribute lines, including an attribute whose arguments
  /// span several lines. Anything else, such as an intervening declaration,
  /// owns the attributes above it and resets the accumulation.
  static String _nextPendingAttributes(String pending, String line) {
    final continuesAttribute =
        pending.isNotEmpty && !_swiftAttributes.hasMatch(pending);
    if (!line.startsWith('@') && !continuesAttribute) return '';
    final next = '$pending $line'.trim();
    if (!next.startsWith('@') ||
        next.contains(';') ||
        next.contains('{') ||
        next.contains('}')) {
      return '';
    }
    return next;
  }

  /// Replace comments and string literal contents with spaces, keeping line
  /// breaks so line-oriented declaration matching still works.
  static String _codeOutsideCommentsAndStrings(String source) {
    const code = 0;
    const quoted = 1;
    const multilineQuoted = 3;

    final result = StringBuffer();
    var index = 0;
    var blockDepth = 0;
    var lineComment = false;
    var stringDelimiter = code;
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
      } else if (stringDelimiter != code) {
        if (!escaped &&
            stringDelimiter == multilineQuoted &&
            source.startsWith('"""', index)) {
          stringDelimiter = code;
          mask(3);
        } else if (!escaped && stringDelimiter == quoted && character == '"') {
          stringDelimiter = code;
          mask(1);
        } else {
          escaped = character == r'\' && !escaped;
          mask(1);
        }
      } else if (source.startsWith('//', index)) {
        lineComment = true;
        mask(2);
      } else if (source.startsWith('/*', index)) {
        blockDepth = 1;
        mask(2);
      } else if (source.startsWith('"""', index)) {
        stringDelimiter = multilineQuoted;
        mask(3);
      } else if (character == '"') {
        stringDelimiter = quoted;
        mask(1);
      } else {
        result.write(character);
        index++;
      }
    }
    return result.toString();
  }

  static int _compareIosVersions(String left, String right) {
    const components = 3;
    final a = left.split('.').map(int.parse).toList();
    final b = right.split('.').map(int.parse).toList();
    for (var index = 0; index < components; index++) {
      final difference =
          (index < a.length ? a[index] : 0) - (index < b.length ? b[index] : 0);
      if (difference != 0) return difference;
    }
    return 0;
  }
}
