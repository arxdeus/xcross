import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/project/pbx_parser.dart';

/// One object in the `objects = { ... }` map of a `project.pbxproj` file.
///
/// Values are kept in the loosely-typed shape the OpenStep-ish plist uses:
/// a bare/quoted string, a `List<Object?>` for `( ... )`, or a nested
/// [PbxObject]-style `Map<String, Object?>` for `{ ... }`.
@internal
@immutable
final class PbxObject {
  const PbxObject(this.id, this.fields);

  /// The 24-hex-digit object id this object is keyed by.
  final String id;
  final Map<String, Object?> fields;

  String? get isa => string('isa');

  /// [key] as a string, or null when absent or not a scalar.
  String? string(String key) {
    final value = fields[key];
    return value is String ? value : null;
  }

  /// [key] as a list of strings, tolerating a single scalar.
  List<String> stringList(String key) {
    final value = fields[key];
    if (value is String) return [value];
    if (value is! List) return const [];
    return value.whereType<String>().toList();
  }

  /// [key] as a nested map (e.g. `buildSettings`).
  Map<String, Object?> map(String key) {
    final value = fields[key];
    return value is Map<String, Object?> ? value : const {};
  }
}

/// A parsed `project.pbxproj`: the flat object graph plus lookup helpers.
///
/// This is a real (small) parser rather than a pile of regexes because app
/// extensions make the file genuinely graph-shaped: resolving one target's
/// bundle id, sources, and resources means walking
/// `PBXNativeTarget` → `XCConfigurationList` → `XCBuildConfiguration` and
/// `PBXNativeTarget` → `PBXSourcesBuildPhase` → `PBXBuildFile` → `PBXFileReference`
/// → `PBXGroup` parents (for the on-disk path).
@internal
@immutable
final class PbxProject {
  const PbxProject(this.objects, this.rootObjectId, this.projectDirectory);

  /// Parse pbxproj [contents]. Throws [FormatException] on malformed input.
  factory PbxProject.parse(
    String contents, {
    required String projectDirectory,
  }) {
    final root = PbxParser(contents).parseArchive();
    final rawObjects = root['objects'];
    final objects = <String, PbxObject>{};
    if (rawObjects is Map<String, Object?>) {
      for (final entry in rawObjects.entries) {
        final value = entry.value;
        if (value is Map<String, Object?>) {
          objects[entry.key] = PbxObject(entry.key, value);
        }
      }
    }
    final rootObject = root['rootObject'];
    return PbxProject(
      objects,
      rootObject is String ? rootObject : null,
      projectDirectory,
    );
  }

  /// Whether [path] is a source file compiled by an iOS target.
  static bool isTargetSource(String path) =>
      _sourceExtensions.contains(p.extension(path));

  /// Whether [path] is conservatively safe to copy as a target resource.
  static bool isTargetResource(String path) {
    final extension = p.extension(path);
    return !isTargetSource(path) && !_nonResourceExtensions.contains(extension);
  }

  final Map<String, PbxObject> objects;

  /// Id of the `PBXProject` object (`rootObject` at the archive top level).
  final String? rootObjectId;

  /// Directory holding the `.xcodeproj`, i.e. the project's `ios/` dir.
  /// `PBXFileReference` paths are resolved relative to this (SOURCE_ROOT).
  final String projectDirectory;

  PbxObject? object(String? id) => id == null ? null : objects[id];

  /// Every object whose `isa` equals [isa].
  Iterable<PbxObject> byIsa(String isa) =>
      objects.values.where((object) => object.isa == isa);

  /// Every `PBXNativeTarget` in the project.
  Iterable<PbxObject> get nativeTargets => byIsa('PBXNativeTarget');

  /// The first native target that produces an application bundle.
  PbxObject? get applicationTarget {
    for (final target in nativeTargets) {
      if (target.string('productType') ==
          'com.apple.product-type.application') {
        return target;
      }
    }
    return null;
  }

  /// The `buildSettings` of [target]'s build configurations, preferring the
  /// configuration named [preferredConfiguration] (usually `Debug`).
  Map<String, Object?> buildSettings(
    PbxObject target, {
    String preferredConfiguration = 'Debug',
  }) {
    final list = object(target.string('buildConfigurationList'));
    if (list == null) return const {};

    Map<String, Object?>? fallback;
    for (final id in list.stringList('buildConfigurations')) {
      final configuration = object(id);
      if (configuration?.isa != 'XCBuildConfiguration') continue;
      final settings = configuration!.map('buildSettings');
      if (settings.isEmpty) continue;
      if (configuration.string('name') == preferredConfiguration) {
        return settings;
      }
      fallback ??= settings;
    }
    return fallback ?? const {};
  }

  /// One build setting of [target] as a string, or null when unset.
  String? buildSetting(PbxObject target, String key) {
    final value = buildSettings(target)[key];
    return value is String ? value : null;
  }

  /// Absolute on-disk paths of the file references in [target]'s build phase
  /// whose `isa` is [phaseIsa] (`PBXSourcesBuildPhase`, `PBXResourcesBuildPhase`).
  ///
  /// Group-relative references are resolved by walking up the `PBXGroup` tree,
  /// so `Share Extension/Base.lproj/MainInterface.storyboard` comes out right.
  List<String> buildPhaseFiles(PbxObject target, String phaseIsa) {
    final paths = <String>[];
    for (final phaseId in target.stringList('buildPhases')) {
      final phase = object(phaseId);
      if (phase?.isa != phaseIsa) continue;
      for (final buildFileId in phase!.stringList('files')) {
        final buildFile = object(buildFileId);
        if (buildFile == null) continue;
        final referenceId = buildFile.string('fileRef');
        final reference = object(referenceId);
        if (reference?.isa == 'PBXVariantGroup') {
          for (final childId in reference!.stringList('children')) {
            final path = resolveFileReference(childId);
            if (path != null) paths.add(path);
          }
          continue;
        }
        final path = resolveFileReference(referenceId);
        if (path != null) paths.add(path);
      }
    }
    return paths;
  }

  /// Absolute path of the `PBXFileReference`/`PBXGroup` with [id].
  String? resolveFileReference(String? id) {
    final reference = object(id);
    if (reference == null) return null;

    final sourceTree = reference.string('sourceTree');
    final path = reference.string('path');
    if (path == null) return null;

    // Absolute and SDK/BUILT_PRODUCTS references aren't project sources.
    if (sourceTree == '<absolute>') return path;
    if (sourceTree == 'SOURCE_ROOT' || sourceTree == '<group>') {
      final prefix = sourceTree == '<group>' ? _groupPrefix(id!) : null;
      return p.normalize(p.joinAll([projectDirectory, ?prefix, path]));
    }
    return null;
  }

  /// Absolute on-disk paths contributed to [target] by Xcode 16 synchronized
  /// folder groups (`PBXFileSystemSynchronizedRootGroup`).
  ///
  /// Xcode 16 stopped listing every file in `PBXSourcesBuildPhase`: a target
  /// can instead point at a folder whose contents are members implicitly, so
  /// the build phase is empty and only the folder is named. Walking the folder
  /// is therefore the only way to recover the target's files, and skipping it
  /// is what makes such a target look like it has no sources at all.
  ///
  /// Files listed in a `membershipExceptions` set for [target] are excluded,
  /// matching Xcode's own "remove from target" behaviour.
  List<String> synchronizedFiles(
    PbxObject target, {
    required HostFileSystemInterface fileSystem,
  }) {
    final paths = <String>[];
    for (final groupId in target.stringList('fileSystemSynchronizedGroups')) {
      final group = object(groupId);
      if (group == null) continue;
      final root = resolveFileReference(groupId);
      if (root == null || !fileSystem.directory(root).existsSync()) continue;

      final excluded = _membershipExceptions(group, target);
      for (final path in _walkSynchronizedRoot(root, fileSystem)) {
        final relative = p.relative(path, from: root);
        if (excluded.contains(relative)) continue;
        paths.add(path);
      }
    }
    paths.sort();
    return paths;
  }

  /// Group-relative paths [group] excludes from [target].
  Set<String> _membershipExceptions(PbxObject group, PbxObject target) {
    final excluded = <String>{};
    for (final exceptionId in group.stringList('exceptions')) {
      final exception = object(exceptionId);
      if (exception == null) continue;
      // An exception set names the one target it applies to; sets belonging to
      // a sibling target must not hide files from this one.
      if (exception.string('target') != target.id) continue;
      excluded.addAll(
        exception.stringList('membershipExceptions').map(p.normalize),
      );
    }
    return excluded;
  }

  /// Files under a synchronized root, treating bundle-shaped directories as
  /// single entries so an `.xcassets` is one resource, not its loose contents.
  static List<String> _walkSynchronizedRoot(
    String root,
    HostFileSystemInterface fileSystem,
  ) {
    const bundleDirectories = {
      '.xcassets',
      '.storyboardc',
      '.framework',
      '.bundle',
      '.xcdatamodeld',
      '.docc',
    };

    final found = <String>[];
    final pending = <String>[root];
    // Bounded walk: pbxproj folders are shallow and this never follows links.
    while (pending.isNotEmpty) {
      final logical = pending.removeLast();
      final directory = fileSystem.directory(logical);
      final List<FileSystemEntity> entries;
      try {
        entries = directory.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        final name = p.basename(entry.path);
        // Xcode ignores dotfiles in synchronized folders.
        if (name.startsWith('.')) continue;
        final path = p.join(logical, name);
        if (entry is Directory) {
          if (bundleDirectories.contains(p.extension(name))) {
            found.add(path);
          } else {
            pending.add(path);
          }
          continue;
        }
        if (entry is File) found.add(path);
      }
    }
    return found;
  }

  /// Path prefix contributed by the `PBXGroup` chain above the object [id].
  String? _groupPrefix(String id) {
    final segments = <String>[];
    var childId = id;
    // Bounded by the number of objects; pbxproj group trees are shallow.
    for (var depth = 0; depth < objects.length; depth++) {
      final parent = _parentGroupOf(childId);
      if (parent == null) break;
      // A variant group's path is the logical resource name, not an on-disk
      // directory. Its children already include their localized paths.
      final path = parent.isa == 'PBXGroup' ? parent.string('path') : null;
      if (path != null && path.isNotEmpty) segments.insert(0, path);
      childId = parent.id;
    }
    return segments.isEmpty ? null : p.joinAll(segments);
  }

  PbxObject? _parentGroupOf(String childId) {
    for (final group in objects.values) {
      final isa = group.isa;
      if (isa != 'PBXGroup' && isa != 'PBXVariantGroup') continue;
      if (group.stringList('children').contains(childId)) return group;
    }
    return null;
  }
}

/// Extensions of files that belong in a target's compile-sources phase.
const _sourceExtensions = {'.swift', '.m', '.mm', '.c', '.cpp'};

/// Build inputs Xcode consumes itself rather than target resources.
const _nonResourceExtensions = {
  '.h',
  '.hpp',
  '.entitlements',
  '.modulemap',
  '.xcconfig',
  '.md',
  '.swiftinterface',
};
