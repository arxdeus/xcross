import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plan_reader.dart';

@internal
final class SwiftPmManifestTargetAlias {
  SwiftPmManifestTargetAlias({required this.fileSystem});
  final SwiftPmArtifactFileSystem fileSystem;

  static const String _indent = '  ';

  Future<bool?> withTargets({
    required String scratchPath,
    required String targetBuildDir,
    required String target,
    required List<String> extra,
    required Future<void> Function() build,
  }) async {
    final manifest = fileSystem.file(
      p.join(scratchPath, '${p.basename(targetBuildDir)}.yaml'),
    );
    final String text;
    try {
      text = await manifest.readAsString();
    } on Object {
      return null;
    }
    final lines = text.split('\n');
    final entries = _targetEntries(lines);
    final suffix = _suffix(entries.keys);
    if (suffix == null) return null;
    final index = entries['$target$suffix'];
    if (index == null) return null;
    final nodes = _decodeNodes(lines[index]);
    if (nodes == null) return null;
    final added = <String>[];
    for (final name in extra) {
      final key = '$name$suffix';
      final entry = entries[key];
      if (entry == null) return null;
      final targetNodes = _decodeNodes(lines[entry]);
      if (targetNodes == null) return null;
      for (final node in targetNodes) {
        if (!nodes.contains(node) && !added.contains(node)) added.add(node);
      }
    }
    if (added.isEmpty) {
      await build();
      return true;
    }
    final original = lines[index];
    final aliased = _encode('$target$suffix', [...nodes, ...added]);
    lines[index] = aliased;
    await manifest.writeAsString(lines.join('\n'));
    var retained = false;
    try {
      await build();
    } finally {
      final restored = (await manifest.readAsString()).split('\n');
      final at = restored.indexOf(aliased);
      retained = at != -1;
      if (retained) {
        restored[at] = original;
        await manifest.writeAsString(restored.join('\n'));
      }
    }
    return retained;
  }

  static Map<String, int> _targetEntries(List<String> lines) {
    final entries = <String, int>{};
    var inTargets = false;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (!line.startsWith(_indent)) {
        if (inTargets) break;
        inTargets = line == 'targets:';
        continue;
      }
      if (!inTargets) continue;
      final separator = line.indexOf('": [');
      if (separator == -1 || !line.startsWith('$_indent"')) continue;
      final Object? key;
      try {
        key = jsonDecode(line.substring(_indent.length, separator + 1));
      } on FormatException {
        continue;
      }
      if (key is String) entries[key] = index;
    }
    return entries;
  }

  static String? _suffix(Iterable<String> keys) {
    const prefix = '$pluginsProductName-';
    for (final key in keys) {
      if (key.startsWith(prefix) && key.endsWith('.module')) {
        return key.substring(pluginsProductName.length);
      }
    }
    return null;
  }

  static List<String>? _decodeNodes(String line) {
    final separator = line.indexOf('": [');
    if (separator == -1) return null;
    try {
      final decoded = jsonDecode(line.substring(separator + 3));
      if (decoded is! List || !decoded.every((node) => node is String)) {
        return null;
      }
      return decoded.cast<String>();
    } on FormatException {
      return null;
    }
  }

  static String _encode(String key, List<String> nodes) =>
      '$_indent${jsonEncode(key)}: ${jsonEncode(nodes)}';
}
