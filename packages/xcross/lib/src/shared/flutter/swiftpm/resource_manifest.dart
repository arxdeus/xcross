import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';
import 'package:xml/xml.dart';

/// One resource SwiftPM copies into a resource bundle with its `copy-tool`.
@internal
@immutable
final class SwiftPmBundleResource {
  const SwiftPmBundleResource({required this.source, required this.relative});

  /// The declared resource in the package sources, as SwiftPM read it.
  final String source;

  /// Its destination relative to the bundle root.
  final String relative;

  @override
  bool operator ==(Object other) =>
      other is SwiftPmBundleResource &&
      other.source == source &&
      other.relative == relative;

  @override
  int get hashCode => Object.hash(source, relative);

  @override
  String toString() => '$relative <- $source';
}

/// A SwiftPM resource bundle (`<Package>_<Target>.bundle`) in the build
/// products directory, with the resources its build manifest copies into it.
@internal
final class SwiftPmResourceBundle {
  const SwiftPmResourceBundle({
    required this.bundlePath,
    this.resources,
    this.packageIdentity,
    this.targetName,
    this.minimumOsVersion,
    this.copyRules,
  });

  final String bundlePath;

  /// SwiftPM's identity of the package declaring the bundle (the checkout or
  /// package directory name, lowercased), when it could be derived.
  final String? packageIdentity;

  /// The target the bundle belongs to, when it could be derived.
  final String? targetName;

  /// The iOS version the target was compiled for, Xcode's
  /// `MinimumOSVersion` of the bundle, when the manifest names it.
  final String? minimumOsVersion;

  /// The paths the target declares with `.copy(...)` in its `Package.swift`
  /// (as written, relative to the target directory), or null when the
  /// manifest could not be read. See [isCopiedVerbatim].
  final List<String>? copyRules;

  /// The Swift module name of [targetName] (its c99 identifier), which
  /// Xcode passes to `ibtool --module`.
  String? get moduleName {
    final target = targetName;
    if (target == null) return null;
    final name = target.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
    return RegExp('^[0-9]').hasMatch(name) ? '_$name' : name;
  }

  /// Whether [resource] is a `.copy(...)` resource, which Xcode ships as-is,
  /// rather than one processed by rule (`.process(...)` or a default rule),
  /// which Xcode compiles (`.xib` to `.nib`).
  ///
  /// SwiftPM's build manifest cannot tell: both are a `copy-tool` command
  /// from the source file (measured with `.process("Res")` and
  /// `.copy("Copied.xib")`). The package manifest can: a `.copy` resource
  /// lands at the basename of its declared path, and its source ends with
  /// that path. Without a readable manifest, a resource counts as processed.
  bool isCopiedVerbatim(SwiftPmBundleResource resource, p.Context paths) {
    final rules = copyRules;
    if (rules == null) return false;
    final source = paths.normalize(resource.source);
    for (final rule in rules) {
      final declared = paths.normalize(rule);
      if (!paths.equals(resource.relative, paths.basename(declared))) {
        continue;
      }
      if (paths.equals(source, declared) ||
          source.endsWith('${paths.separator}$declared')) {
        return true;
      }
    }
    return false;
  }

  /// Xcode's `CFBundleIdentifier` for the bundle,
  /// `<package identity>.<target>.resources`, with every character outside
  /// `[A-Za-z0-9.-]` replaced by `-` (measured: `file_picker_darwin-1.0.4`
  /// and target `file_picker_darwin` give
  /// `file-picker-darwin-1.0.4.file-picker-darwin.resources`).
  String? get bundleIdentifier {
    final identity = packageIdentity;
    final target = targetName;
    if (identity == null || target == null) return null;
    return '$identity.$target.resources'.replaceAll(
      RegExp('[^A-Za-z0-9.-]'),
      '-',
    );
  }

  /// The `copy-tool` resources of this bundle, or null when the build
  /// manifest was missing or did not describe it.
  final List<SwiftPmBundleResource>? resources;
}

/// [output] (bundle-relative segments of a `copy-tool` output) with every
/// `.lproj` segment given the casing of the same directory in [input] (the
/// source path's segments).
///
/// `swift build` lowercases localization directories in its outputs
/// (`Loc/en_GB.lproj/X.strings` lands at `en_gb.lproj/X.strings`); Xcode
/// keeps the source name (`GoogleSignIn_GoogleSignIn.bundle/en_GB.lproj`),
/// and bundle lookup is case-sensitive on device. A `.process` resource's
/// localization directory may sit deeper in the source
/// (`Strings/en_GB.lproj/...`) than in the bundle, so segments are matched
/// case-insensitively by name rather than by position, nearest the file
/// first.
@internal
List<String> restoreLprojCasing(Iterable<String> output, List<String> input) {
  final sources = input.reversed
      .where((segment) => segment.toLowerCase().endsWith('.lproj'))
      .toList();
  final segments = output.toList();
  for (var i = segments.length - 1; i >= 0; i--) {
    final segment = segments[i];
    if (!segment.toLowerCase().endsWith('.lproj')) continue;
    final match = sources.indexWhere(
      (source) => source.toLowerCase() == segment.toLowerCase(),
    );
    if (match < 0) continue;
    segments[i] = sources[match];
    sources.removeAt(match);
  }
  return segments;
}

/// Reads the `copy-tool` commands of SwiftPM's llbuild manifest
/// (`<scratch>/debug.yaml`) and groups them by the `*.bundle` directory
/// their output lands in, keyed by bundle directory name.
///
/// Inputs and outputs are JSON arrays of host paths; a directory ends with a
/// separator. Outputs outside a `*.bundle` directory are ignored.
@internal
Map<String, List<SwiftPmBundleResource>> parseSwiftPmResourceCopies(
  String manifest,
  p.Context paths,
) {
  final result = <String, List<SwiftPmBundleResource>>{};
  String? tool;
  List<String>? inputs;
  List<String>? outputs;

  void flush() {
    if (tool == 'copy-tool' &&
        inputs != null &&
        outputs != null &&
        inputs!.length == 1 &&
        outputs!.length == 1) {
      final segments = paths.split(_trimSeparator(outputs!.single, paths));
      final index = segments.indexWhere(
        (segment) => paths.extension(segment) == '.bundle',
      );
      if (index >= 0 && index < segments.length - 1) {
        result
            .putIfAbsent(segments[index], () => [])
            .add(
              SwiftPmBundleResource(
                source: _trimSeparator(inputs!.single, paths),
                relative: paths.joinAll(
                  restoreLprojCasing(
                    segments.skip(index + 1),
                    paths.split(_trimSeparator(inputs!.single, paths)),
                  ),
                ),
              ),
            );
      }
    }
    tool = null;
    inputs = null;
    outputs = null;
  }

  for (final line in const LineSplitter().convert(manifest)) {
    final trimmed = line.trimLeft();
    final indent = line.length - trimmed.length;
    if (trimmed.isEmpty) continue;
    if (indent <= 2) {
      flush();
      continue;
    }
    if (trimmed.startsWith('tool:')) {
      tool = trimmed.substring('tool:'.length).trim();
    } else if (trimmed.startsWith('inputs:')) {
      inputs = _jsonList(trimmed.substring('inputs:'.length));
    } else if (trimmed.startsWith('outputs:')) {
      outputs = _jsonList(trimmed.substring('outputs:'.length));
    }
  }
  flush();
  return result;
}

/// The targets whose objects SwiftPM's build manifest links into each
/// dynamic library or framework binary, keyed by that binary's path: the
/// `<Target>.build` directory of every `.o` input of a `shell` command whose
/// single output is a `.dylib` or a binary directly inside a `.framework`.
/// Xcode embeds the resource bundles of exactly the targets linked into what
/// the app embeds; targets that were only compiled (plan builds, sibling
/// products such as `SDWebImageMapKit`) do not count.
@internal
Map<String, Set<String>> parseSwiftPmLinkedTargets(
  String manifest,
  p.Context paths,
) {
  final result = <String, Set<String>>{};
  String? tool;
  List<String>? inputs;
  List<String>? outputs;

  void flush() {
    final output = outputs?.length == 1 ? outputs!.single : null;
    if (tool == 'shell' &&
        inputs != null &&
        output != null &&
        (paths.extension(output) == '.dylib' ||
            paths.extension(paths.dirname(output)) == '.framework')) {
      final targets = result.putIfAbsent(output, () => <String>{});
      for (final input in inputs!) {
        if (paths.extension(input) != '.o') continue;
        for (final segment in paths.split(paths.dirname(input))) {
          if (paths.extension(segment) == '.build') {
            targets.add(paths.basenameWithoutExtension(segment));
          }
        }
      }
    }
    tool = null;
    inputs = null;
    outputs = null;
  }

  for (final line in const LineSplitter().convert(manifest)) {
    final trimmed = line.trimLeft();
    final indent = line.length - trimmed.length;
    if (trimmed.isEmpty) continue;
    if (indent <= 2) {
      flush();
      continue;
    }
    if (trimmed.startsWith('tool:')) {
      tool = trimmed.substring('tool:'.length).trim();
    } else if (trimmed.startsWith('inputs:')) {
      inputs = _jsonList(trimmed.substring('inputs:'.length));
    } else if (trimmed.startsWith('outputs:')) {
      outputs = _jsonList(trimmed.substring('outputs:'.length));
    }
  }
  flush();
  return result;
}

List<String>? _jsonList(String text) {
  try {
    final decoded = jsonDecode(text.trim());
    if (decoded is List && decoded.every((e) => e is String)) {
      return decoded.cast<String>();
    }
  } on FormatException {
    // Not a JSON array: not a command shape this reader understands.
  }
  return null;
}

String _trimSeparator(String path, p.Context paths) {
  var trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') ||
          (paths.style == p.Style.windows && trimmed.endsWith(r'\')))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

/// The OS version of the `-target` triple SwiftPM compiles each target with
/// (the package's declared platform minimum), keyed by target name. A
/// compile command is attributed to the target whose `<Target>.build`
/// directory its arguments write into.
@internal
Map<String, String> parseSwiftPmTargetDeploymentVersions(String manifest) {
  final result = <String, String>{};
  for (final line in const LineSplitter().convert(manifest)) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('args:')) continue;
    final args = _jsonList(trimmed.substring('args:'.length));
    if (args == null) continue;
    final index = args.indexOf('-target');
    if (index < 0 || index + 1 >= args.length) continue;
    final version = RegExp(
      r'-ios(\d+(?:\.\d+)*)',
    ).firstMatch(args[index + 1])?.group(1);
    if (version == null) continue;
    final moduleIndex = args.indexOf('-module-name');
    if (moduleIndex >= 0 && moduleIndex + 1 < args.length) {
      result.putIfAbsent(args[moduleIndex + 1], () => version);
    }
    for (final arg in args) {
      final match = RegExp(r'[/\\]([^/\\]+)\.build[/\\]').firstMatch(arg);
      if (match != null) {
        result.putIfAbsent(match.group(1)!, () => version);
        break;
      }
    }
  }
  return result;
}

/// SwiftPM package identities by the directory their sources live in, read
/// from `<scratch>/workspace-state.json`: `<scratch>/checkouts/<subpath>` for
/// a source-control dependency, the declared `location` for a path one.
@internal
Map<String, String> parseSwiftPmPackageLocations(
  String workspaceState,
  String scratchPath,
  p.Context paths,
) {
  final result = <String, String>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(workspaceState);
  } on FormatException {
    return result;
  }
  if (decoded is! Map) return result;
  final object = decoded['object'];
  final dependencies = object is Map ? object['dependencies'] : null;
  if (dependencies is! List) return result;
  for (final dependency in dependencies) {
    if (dependency is! Map) continue;
    final reference = dependency['packageRef'];
    if (reference is! Map) continue;
    final identity = reference['identity'];
    if (identity is! String) continue;
    final kind = reference['kind'];
    final location = reference['location'];
    final subpath = dependency['subpath'];
    if (kind == 'fileSystem' || kind == 'localSourceControl') {
      if (location is String) result[paths.normalize(location)] = identity;
    }
    if (kind != 'fileSystem' && subpath is String) {
      result[paths.join(scratchPath, 'checkouts', subpath)] = identity;
    }
  }
  return result;
}

/// A package of SwiftPM's `<scratch>/workspace-state.json`: its identity,
/// the name its manifest declares (the `<Package>` of its resource bundles,
/// `<Package>_<Target>.bundle`), and the directory holding its manifest.
@internal
@immutable
final class SwiftPmPackageReference {
  const SwiftPmPackageReference({
    required this.identity,
    required this.name,
    required this.directory,
  });

  final String identity;
  final String name;
  final String directory;

  @override
  bool operator ==(Object other) =>
      other is SwiftPmPackageReference &&
      other.identity == identity &&
      other.name == name &&
      other.directory == directory;

  @override
  int get hashCode => Object.hash(identity, name, directory);

  @override
  String toString() => '$identity ($name) at $directory';
}

/// The packages of [workspaceState] that declare a manifest name:
/// `<scratchPath>/checkouts/<subpath>` for a source-control dependency, the
/// declared `location` for a path one.
@internal
List<SwiftPmPackageReference> parseSwiftPmPackageReferences(
  String workspaceState,
  String scratchPath,
  p.Context paths,
) {
  final result = <SwiftPmPackageReference>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(workspaceState);
  } on FormatException {
    return result;
  }
  if (decoded is! Map) return result;
  final object = decoded['object'];
  final dependencies = object is Map ? object['dependencies'] : null;
  if (dependencies is! List) return result;
  for (final dependency in dependencies) {
    if (dependency is! Map) continue;
    final reference = dependency['packageRef'];
    if (reference is! Map) continue;
    final identity = reference['identity'];
    final name = reference['name'];
    if (identity is! String || name is! String || name.isEmpty) continue;
    final kind = reference['kind'];
    final location = reference['location'];
    final subpath = dependency['subpath'];
    final String directory;
    if (kind == 'fileSystem' && location is String) {
      directory = paths.normalize(location);
    } else if (subpath is String) {
      directory = paths.join(scratchPath, 'checkouts', subpath);
    } else {
      continue;
    }
    result.add(
      SwiftPmPackageReference(
        identity: identity,
        name: name,
        directory: directory,
      ),
    );
  }
  return result;
}

/// The package and target of [bundleName] (`<Package>_<Target>.bundle`,
/// `<Package>` the manifest name, so `GoogleUtilities_GoogleUtilities-Logger`
/// is target `GoogleUtilities-Logger` of `googleutilities`): the package of
/// [packages] with the longest name prefix.
@internal
({SwiftPmPackageReference package, String target})? packageOfBundle(
  String bundleName,
  Iterable<SwiftPmPackageReference> packages,
) {
  final stem = bundleName.endsWith('.bundle')
      ? bundleName.substring(0, bundleName.length - '.bundle'.length)
      : bundleName;
  SwiftPmPackageReference? best;
  for (final package in packages) {
    final prefix = '${package.name}_';
    if (!stem.startsWith(prefix) || stem.length == prefix.length) continue;
    if (best == null || package.name.length > best.name.length) {
      best = package;
    }
  }
  if (best == null) return null;
  return (package: best, target: stem.substring(best.name.length + 1));
}

/// The paths [target]'s `.target(...)` declaration in [manifest] (a
/// `Package.swift`) copies verbatim with `.copy("...")`.
@internal
List<String> swiftPmTargetCopyRules(String manifest, String target) {
  final code = SwiftPmManifestLexer.swiftCodeMask(manifest);
  final result = <String>[];
  for (final kind in const ['.target', '.executableTarget']) {
    for (final call in SwiftPmManifestLexer.swiftCalls(manifest, kind)) {
      if (!code[call.start]) continue;
      if (SwiftPmManifestLexer.namedString(call.text, 'name') != target) {
        continue;
      }
      for (final copy in SwiftPmManifestLexer.swiftCalls(call.text, '.copy')) {
        final literal = RegExp(
          r'^\.copy\s*\(\s*"([^"]+)"',
        ).firstMatch(copy.text);
        if (literal != null) result.add(literal[1]!);
      }
    }
  }
  return result;
}

/// The oldest iOS Xcode 26.6 deploys a SwiftPM package to: the default of
/// a package declaring no iOS platform, and the floor of one declaring an
/// older one (measured: SDWebImage `.iOS(.v9)` and leveldb, declaring none,
/// both get `MinimumOSVersion` 12.0).
@internal
const String swiftPmOldestIosVersion = '12.0';

/// Xcode's `MinimumOSVersion` for the resource bundles of a package with
/// [manifest] (its `Package.swift`): the declared `.iOS(...)` platform,
/// raised to [swiftPmOldestIosVersion].
@internal
String swiftPmPackageMinimumOsVersion(String manifest) {
  final declared = SwiftPmManifestLexer.iosPlatformVersions(manifest);
  var result = swiftPmOldestIosVersion;
  for (final version in declared.take(1)) {
    if (_compareVersions(version, result) > 0) result = version;
  }
  return result;
}

int _compareVersions(String left, String right) {
  final a = left.split('.').map(int.parse).toList();
  final b = right.split('.').map(int.parse).toList();
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// The SwiftPM identity Xcode gives each Flutter plugin package, keyed by
/// plugin name: flutter_tools links every plugin into
/// `ephemeral/Packages/.packages` under its pub package directory basename
/// (`file_picker_darwin-1.0.4`, carrying the version) and rewrites a
/// plugin's `"../<dependency>"` path to that versioned basename too, so the
/// identity is the lowercased basename (measured: `firebase_core-4.15.0`,
/// `webview_flutter_wkwebview-3.26.1`, a path plugin `flutter_chrome_cast`).
/// Mirrors `_dependenciesForPlugins` and `_getPluginDependencies` in
/// flutter_tools' `swift_package_manager.dart`. [plugins] holds each
/// plugin's package directory basename.
@internal
Map<String, String> flutterPluginSwiftPmIdentities(
  Map<String, String> plugins,
) => {
  for (final MapEntry(key: name, value: basename) in plugins.entries)
    name: basename.toLowerCase(),
};

/// The identity of the package whose directory holds [source], the
/// deepest match in [locations].
@internal
String? packageIdentityOf(
  String source,
  Map<String, String> locations,
  p.Context paths,
) {
  String? best;
  String? identity;
  for (final entry in locations.entries) {
    if (!paths.isWithin(entry.key, paths.normalize(source))) continue;
    if (best != null && entry.key.length <= best.length) continue;
    best = entry.key;
    identity = entry.value;
  }
  return identity;
}

/// The target of [bundleName] (`<Package>_<Target>.bundle`): the longest
/// `<Target>` of [targets] that the name ends with.
@internal
String? targetOfBundle(String bundleName, Iterable<String> targets) {
  final stem = bundleName.endsWith('.bundle')
      ? bundleName.substring(0, bundleName.length - '.bundle'.length)
      : bundleName;
  String? best;
  for (final target in targets) {
    if (!stem.endsWith('_$target')) continue;
    if (best == null || target.length > best.length) best = target;
  }
  return best;
}

/// The bundles of [copies] (from [parseSwiftPmResourceCopies]) that
/// `swift build` declared but did not leave in the products directory
/// ([listed] holds the bundle names it did leave), for a target ([targets],
/// the `<Target>.build` directory names) that is linked into a binary the
/// app embeds ([linked], from [parseSwiftPmLinkedTargets]), sorted.
///
/// llbuild records a `copy-tool` output that is a dangling link (SDWebImage
/// copies `Resources/PrivacyInfo.xcprivacy`, a git symlink pointing outside
/// the target) as missing, and a missing output looks up to date, so once
/// the products directory is wiped (every plugin rebuild deletes it) such a
/// bundle is never recreated. Xcode builds it from the sources regardless.
@internal
List<String> missingSwiftPmResourceBundles(
  Map<String, List<SwiftPmBundleResource>> copies,
  Set<String> listed,
  Iterable<String> targets,
  Set<String> linked,
) {
  final known = {...targets, ...linked};
  return [
    for (final entry in copies.entries)
      if (!listed.contains(entry.key) &&
          entry.value.isNotEmpty &&
          linked.contains(targetOfBundle(entry.key, known)))
        entry.key,
  ]..sort();
}

/// The `Info.plist` Xcode generates for a SwiftPM resource bundle, before
/// the platform and toolchain (`DT*`) keys are stamped in, measured against
/// Xcode 26.6: development region `en`, `<identity>.<target>.resources`
/// identifier, `BNDL` package type, the target's own `MinimumOSVersion`
/// (falling back to [deploymentTarget]), [developmentRegion] (the
/// package's `defaultLocalization`, else `en`), `UIDeviceFamily` 1 and 2, and
/// `UIRequiredDeviceCapabilities` `arm64` for device builds only.
@internal
String swiftPmResourceBundleInfoPlist(
  SwiftPmResourceBundle bundle, {
  required String deploymentTarget,
  required bool device,
  required p.Context paths,
  String developmentRegion = 'en',
}) {
  final name = paths.basenameWithoutExtension(bundle.bundlePath);
  final identifier = bundle.bundleIdentifier ?? '$name.resources';
  String escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
      ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '\t<key>CFBundleDevelopmentRegion</key>\n'
      '\t<string>${escape(developmentRegion)}</string>\n'
      '\t<key>CFBundleIdentifier</key>\n'
      '\t<string>${escape(identifier)}</string>\n'
      '\t<key>CFBundleInfoDictionaryVersion</key>\n'
      '\t<string>6.0</string>\n'
      '\t<key>CFBundleName</key>\n'
      '\t<string>${escape(name)}</string>\n'
      '\t<key>CFBundlePackageType</key>\n'
      '\t<string>BNDL</string>\n'
      '\t<key>MinimumOSVersion</key>\n'
      '\t<string>${bundle.minimumOsVersion ?? deploymentTarget}</string>\n'
      '\t<key>UIDeviceFamily</key>\n'
      '\t<array>\n'
      '\t\t<integer>1</integer>\n'
      '\t\t<integer>2</integer>\n'
      '\t</array>\n'
      '${device ? '\t<key>UIRequiredDeviceCapabilities</key>\n'
                '\t<array>\n'
                '\t\t<string>arm64</string>\n'
                '\t</array>\n' : ''}'
      '</dict>\n'
      '</plist>\n';
}

/// `CFBundleDevelopmentRegion` from the partial `Info.plist` SwiftPM writes
/// into a resource bundle of a package declaring `defaultLocalization`, or
/// null when [xml] is not a plist or has none.
@internal
String? swiftPmDevelopmentRegion(String xml) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xml);
  } on XmlException {
    return null;
  }
  final dict = document.rootElement.getElement('dict');
  if (dict == null) return null;
  final children = dict.childElements.toList();
  for (var i = 0; i + 1 < children.length; i++) {
    if (children[i].name.local == 'key' &&
        children[i].innerText == 'CFBundleDevelopmentRegion' &&
        children[i + 1].name.local == 'string') {
      final value = children[i + 1].innerText.trim();
      return value.isEmpty ? null : value;
    }
  }
  return null;
}
