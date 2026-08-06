import 'dart:io';

/// Tracks which `lib/` `.dart` files changed between compiles, so a hot reload
/// only recompiles what the user actually edited.
final class SourceWatcher {
  SourceWatcher(this.projectRoot);

  /// Flutter project root directory.
  final String projectRoot;

  // Content hash of each file at the last compile, the change-detection
  // baseline.
  final Map<String, int> _hashes = {};

  /// Every `lib/` `.dart` file, as absolute paths. Scoped to `lib/` since
  /// `test/`/`bin/`/`tool/` pull in non-runtime deps that would balloon the
  /// compile.
  List<String> dartFiles() {
    final root = _searchRoot();
    if (root == null) return const [];

    final files = <String>[];
    final pending = <Directory>[root];
    while (pending.isNotEmpty) {
      final List<FileSystemEntity> entries;
      try {
        entries = pending.removeLast().listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entity in entries) {
        final name = _basename(entity);
        if (entity is Directory) {
          if (!name.startsWith('.') && name != 'build') pending.add(entity);
        } else if (entity is File && name.endsWith('.dart')) {
          files.add(entity.absolute.path);
        }
      }
    }
    return files;
  }

  /// Record the current content hash of every `lib/` `.dart` file as the
  /// baseline for [changedFileUris].
  void snapshot() {
    _hashes.clear();
    for (final path in dartFiles()) {
      if (_contentHash(path) case final hash?) _hashes[path] = hash;
    }
  }

  /// `lib/` `.dart` files whose content changed since the last snapshot, as
  /// `file://` URIs. NOT a pure query: it advances the baseline as it walks,
  /// so a second call returns empty.
  List<String> changedFileUris() {
    final changed = <String>[];
    for (final path in dartFiles()) {
      final hash = _contentHash(path);
      if (hash == null || _hashes[path] == hash) continue;
      _hashes[path] = hash;
      changed.add(Uri.file(path).toString());
    }
    return changed;
  }

  // `<projectRoot>/lib`, falling back to the project root, or null if
  // neither exists.
  Directory? _searchRoot() {
    for (final path in ['$projectRoot/lib', projectRoot]) {
      final dir = Directory(path);
      if (dir.existsSync()) return dir;
    }
    return null;
  }

  static String _basename(FileSystemEntity entity) =>
      entity.uri.pathSegments.where((s) => s.isNotEmpty).last;

  // Null when the file cannot be read (deleted mid-walk, permissions).
  static int? _contentHash(String path) {
    try {
      return _fnv1a(File(path).readAsBytesSync());
    } on Object catch (_) {
      return null;
    }
  }

  // 64-bit FNV-1a hash (mtime is unreliable over virtiofs). Offset basis
  // 0xCBF2_9CE4_8422_2325, prime 0x100_0000_01B3.
  static int _fnv1a(List<int> bytes) {
    // ignore: avoid_js_rounded_ints
    var hash = 0xCBF2_9CE4_8422_2325;
    for (final byte in bytes) {
      hash = (hash ^ byte) * 0x100_0000_01B3;
    }
    return hash & 0x7FFF_FFFF_FFFF_FFFF;
  }
}
