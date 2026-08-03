import 'dart:io';

import 'package:xcross_flutter/src/models/hot_reload_config.dart';

/// Tracks which `lib/` `.dart` files changed between compiles, so a hot reload
/// only recompiles what the user actually edited.
class SourceWatcher {
  SourceWatcher(this.config);

  final HotReloadConfig config;

  /// Content hash of each `lib/` `.dart` file at the last compile — the
  /// baseline for change detection.
  final Map<String, int> _hashes = {};

  /// Every `lib/` `.dart` file, as absolute paths.
  ///
  /// Scope is `lib/` on purpose: `test/`/`bin/`/`tool/` import non-runtime deps
  /// (e.g. `flutter_test`) that would balloon the compile. The walk is pruned
  /// so `.fvm`/`.dart_tool`/`build`/`.git` aren't traversed.
  List<String> dartFiles() {
    var root = Directory('${config.projectRoot}/lib');
    if (!root.existsSync()) root = Directory(config.projectRoot);
    if (!root.existsSync()) return const [];
    final files = <String>[];
    final stack = <Directory>[root];
    while (stack.isNotEmpty) {
      final dir = stack.removeLast();
      final List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entity in entries) {
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (entity is Directory) {
          if (name.startsWith('.') || name == 'build') continue;
          stack.add(entity);
        } else if (entity is File && name.endsWith('.dart')) {
          files.add(entity.absolute.path);
        }
      }
    }
    return files;
  }

  /// Record the current content hash of every `lib/` `.dart` file, establishing
  /// the baseline for [changedFileUris].
  void snapshot() {
    _hashes.clear();
    for (final path in dartFiles()) {
      try {
        _hashes[path] = _fnv1a(File(path).readAsBytesSync());
      } catch (_) {}
    }
  }

  /// `lib/` `.dart` files whose *content* changed since the last snapshot, as
  /// `file://` URIs. Content-based so it reliably catches an edit on the first
  /// `r` regardless of mtime/clock behaviour, and returns empty when nothing
  /// actually changed (so we skip a pointless recompile).
  ///
  /// NOT a pure query: it advances the baseline as it walks, so a second call
  /// returns empty. [restart] relies on that.
  List<String> changedFileUris() {
    final changed = <String>[];
    for (final path in dartFiles()) {
      final int hash;
      try {
        hash = _fnv1a(File(path).readAsBytesSync());
      } catch (_) {
        continue;
      }
      if (_hashes[path] != hash) {
        changed.add(Uri.file(path).toString());
        _hashes[path] = hash;
      }
    }
    return changed;
  }

  /// 64-bit FNV-1a hash of file bytes — cheap, collision-safe enough to detect
  /// edits by content (mtime is unreliable over the virtiofs mount this tool
  /// runs over). Offset basis 0xcbf29ce484222325, prime 0x100000001b3.
  static int _fnv1a(List<int> bytes) {
    // Native (dart compile exe) 64-bit ints; JS rounding doesn't apply.
    // ignore: avoid_js_rounded_ints
    var hash = 0xcbf29ce484222325;
    for (final b in bytes) {
      hash = (hash ^ b) * 0x100000001b3;
    }
    return hash & 0x7fffffffffffffff;
  }
}
