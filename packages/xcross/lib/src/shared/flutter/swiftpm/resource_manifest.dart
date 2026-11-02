import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
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
                relative: paths.joinAll(segments.skip(index + 1)),
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
    if (!paths.isWithin(entry.key, source)) continue;
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
