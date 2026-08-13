import 'dart:io';

import 'package:path/path.dart' as p;

/// Content-hash watcher over a KMP module's Kotlin sources.
///
/// Deliberately separate from the Flutter [SourceWatcher]: that one is scoped
/// to `lib/**.dart` and is owned by the frontend_server reload path, while a
/// Compose rebuild is driven by `src/**` Kotlin/Gradle inputs. Sharing one
/// class would mean a config object whose options are always wrong for one of
/// the two callers.
///
/// Hash-based rather than mtime-based for the same reason as the Flutter
/// watcher: mtime is unreliable on virtiofs/WSL mounts and across the Gradle
/// daemon's own writes, and a spurious "changed" here costs a ~2 minute
/// Kotlin/Native rebuild.
final class KotlinSourceWatcher {
  KotlinSourceWatcher(this.projectRoot, {List<String>? searchRoots})
    : _searchRoots = searchRoots;

  /// KMP project root (the directory holding `settings.gradle.kts`).
  final String projectRoot;

  final List<String>? _searchRoots;

  final Map<String, int> _hashes = {};

  /// Extensions that can change what the built framework contains.
  ///
  /// Gradle files matter as much as Kotlin here: a dependency bump in
  /// `build.gradle.kts` changes the framework without touching a single
  /// `.kt` file.
  static const _watchedExtensions = {
    '.kt',
    '.kts',
    '.klib',
    '.toml',
    '.properties',
  };

  /// Directories that never contain hand-edited sources. `build/` is the big
  /// one: it holds Gradle's own outputs, which change on every build and would
  /// make every check report "changed" forever.
  static const _skippedDirectories = {
    'build',
    '.gradle',
    '.git',
    '.idea',
    '.kotlin',
    'DerivedData',
  };

  /// Every watched source file under the project, as absolute paths.
  List<String> sourceFiles() {
    final files = <String>[];
    for (final root in _roots()) {
      final directory = Directory(root);
      if (!directory.existsSync()) continue;
      final pending = <Directory>[directory];
      while (pending.isNotEmpty) {
        final List<FileSystemEntity> entries;
        try {
          entries = pending.removeLast().listSync(followLinks: false);
        } on FileSystemException {
          continue;
        }
        for (final entity in entries) {
          final name = p.basename(entity.path);
          if (entity is Directory) {
            if (name.startsWith('.') || _skippedDirectories.contains(name)) {
              continue;
            }
            pending.add(entity);
          } else if (entity is File &&
              _watchedExtensions.contains(p.extension(name))) {
            files.add(entity.absolute.path);
          }
        }
      }
    }
    files.sort();
    return files;
  }

  /// Record the current content of every watched file as the baseline.
  void snapshot() {
    _hashes
      ..clear()
      ..addAll({
        for (final path in sourceFiles())
          if (_contentHash(path) case final hash?) path: hash,
      });
  }

  /// Whether any watched file changed since [snapshot]. Advances the baseline,
  /// so an immediate second call returns false.
  bool hasChanges() => changedFiles().isNotEmpty;

  /// Watched files added, removed, or edited since the last snapshot.
  /// NOT a pure query: it advances the baseline as it walks.
  List<String> changedFiles() {
    final changed = <String>[];
    final seen = <String>{};
    for (final path in sourceFiles()) {
      seen.add(path);
      final hash = _contentHash(path);
      if (hash == null) continue;
      if (_hashes[path] != hash) {
        _hashes[path] = hash;
        changed.add(path);
      }
    }
    // A deleted file changes the build just as much as an edited one.
    for (final path in _hashes.keys.toList()) {
      if (!seen.contains(path)) {
        _hashes.remove(path);
        changed.add(path);
      }
    }
    return changed;
  }

  /// Drop [paths] from the baseline so the next check reports them as
  /// changed again. Used after a failed build: the walk already advanced the
  /// baseline, so without this a retry would see "no changes" and skip the
  /// rebuild the user is waiting for.
  void invalidate(Iterable<String> paths) {
    for (final path in paths) {
      _hashes.remove(path);
    }
  }

  List<String> _roots() => _searchRoots ?? [projectRoot];

  // Null when the file cannot be read (deleted mid-walk, permissions).
  static int? _contentHash(String path) {
    try {
      return _fnv1a(File(path).readAsBytesSync());
    } on Object catch (_) {
      return null;
    }
  }

  // 64-bit FNV-1a, matching the Flutter watcher's hash.
  static int _fnv1a(List<int> bytes) {
    // ignore: avoid_js_rounded_ints
    var hash = 0xCBF2_9CE4_8422_2325;
    for (final byte in bytes) {
      hash = (hash ^ byte) * 0x100_0000_01B3;
    }
    return hash & 0x7FFF_FFFF_FFFF_FFFF;
  }
}
