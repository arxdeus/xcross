import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/compose/project/ios_app_config.dart';

/// The iOS app target's `.entitlements` file, as the Compose build sees it.
///
/// The entitlements are what tell provisioning which App ID capabilities the app
/// needs. Without them a project that signs in with Apple, uses passkeys, or
/// authenticates through an `ASWebAuthenticationSession` gets a profile that
/// grants none of it, and the failure shows up at runtime rather than at build
/// time.
abstract final class ComposeEntitlements {
  /// The parsed entitlements of the app target, or null when it has none.
  ///
  /// A file that cannot be read or parsed is treated as "no entitlements"
  /// rather than as a build failure. These values only ever *add* capabilities
  /// to the profile, so failing the build over a malformed one would turn a
  /// project that builds today into one that does not, for a file Xcode itself
  /// may never have required.
  static Map<String, Object?>? read(
    String root,
    String appName, {
    String? appDir,
  }) {
    final path = find(root, appName, appDir: appDir);
    if (path == null) return null;
    try {
      final object = PropertyListSerialization.propertyListWithString(
        File(path).readAsStringSync(),
      );
      if (object is! Map) return null;
      return object.cast<String, Object?>();
    } on Object {
      return null;
    }
  }

  /// The path of the app target's entitlements file, or null.
  ///
  /// [appDir] is the directory of the app target's `@main` Swift file when the
  /// project has one; an entitlements file sits next to it, so it is both the
  /// cheapest and the most accurate place to look. The `iosApp` layouts follow,
  /// matching where the Info.plist is looked for, and only then does it scan -
  /// a Compose project may keep its iOS app anywhere.
  static String? find(String root, String appName, {String? appDir}) {
    final iosApp = IosAppConfig.directory(root);
    for (final directory in [
      if (appDir != null) Directory(appDir),
      if (iosApp != null) ...[
        Directory(p.join(iosApp, 'iosApp')),
        Directory(iosApp),
      ],
      Directory(p.join(root, 'iosApp', 'iosApp')),
      Directory(p.join(root, 'iosApp')),
    ]) {
      final found = _preferred(_filesIn(directory), appName);
      if (found != null) return found;
    }
    final scanned = <String>[];
    _scan(Directory(root), scanned, 0);
    scanned.sort();
    return _preferred(scanned, appName);
  }

  /// Depth the scan descends to. An app target's entitlements sit next to its
  /// Info.plist, a couple of directories below the root at most; anything deeper
  /// is a vendor checkout or generated output.
  static const _maxDepth = 4;

  /// Directories that never hold the app target, and are expensive or wrong to
  /// walk: build output holds copies of the entitlements, and a dependency
  /// manager's tree holds other projects' ones.
  static const _pruned = {
    '.git',
    '.gradle',
    '.dart_tool',
    '.idea',
    'build',
    'node_modules',
    'Pods',
    'DerivedData',
    'vendor',
  };

  static void _scan(Directory directory, List<String> out, int depth) {
    if (depth > _maxDepth) return;
    final List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is Directory) {
        if (_pruned.contains(name) || name.startsWith('.')) continue;
        _scan(entry, out, depth + 1);
      } else if (entry is File && name.endsWith('.entitlements')) {
        out.add(entry.path);
      }
    }
  }

  static List<String> _filesIn(Directory directory) {
    if (!directory.existsSync()) return const [];
    return [
      for (final entity in directory.listSync(followLinks: false))
        if (entity is File && entity.path.endsWith('.entitlements'))
          entity.path,
    ]..sort();
  }

  /// Picks between candidates: the app's own name wins, then an `iosApp`
  /// directory, then a lone candidate. Anything else is ambiguity, and guessing
  /// would enable capabilities on an App ID for a target that never asked.
  static String? _preferred(List<String> candidates, String appName) {
    if (candidates.isEmpty) return null;
    final wanted = appName.toLowerCase();
    for (final candidate in candidates) {
      if (p.basenameWithoutExtension(candidate).toLowerCase() == wanted) {
        return candidate;
      }
    }
    final inIosApp = [
      for (final candidate in candidates)
        if (p.split(candidate).contains('iosApp')) candidate,
    ];
    if (inIosApp.length == 1) return inIosApp.single;
    return candidates.length == 1 ? candidates.single : null;
  }
}
