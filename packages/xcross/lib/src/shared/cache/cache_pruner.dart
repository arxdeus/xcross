import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

/// One cache entry `xcross cache prune` may remove.
@internal
@immutable
final class CacheEntry {
  const CacheEntry({
    required this.path,
    required this.kind,
    required this.engine,
    required this.lastUsed,
    required this.bytes,
  });

  final String path;

  /// `gen-snapshot` or `flutter-engine`.
  final String kind;

  /// Flutter engine revision the entry belongs to.
  final String engine;
  final DateTime lastUsed;
  final int bytes;
}

/// The outcome of a prune: what was (or, on a dry run, would be) removed.
@internal
@immutable
final class CachePruneResult {
  const CachePruneResult({required this.removed, required this.kept});

  final List<CacheEntry> removed;
  final List<CacheEntry> kept;

  int get freedBytes => removed.fold(0, (sum, entry) => sum + entry.bytes);
}

/// Finds and removes Flutter caches xcross downloaded for engines nothing
/// uses any more.
///
/// Every entry is keyed by a Flutter engine revision: iOS engine artifacts
/// under `flutter-engine/<engine>/` and compilers under
/// `gen-snapshot/<engine>/<mode>/<platform>/`. An entry is removed only when
/// its engine belongs to none of the Flutter SDKs passed as [inUseEngines]
/// *and* it has not been used for [olderThan], so neither a switch back to a
/// recent Flutter version nor an SDK xcross could not discover loses its
/// cache.
///
/// Kotlin/Native toolchains are deliberately left alone: they live in
/// `~/.konan`, which Gradle builds outside xcross share.
@internal
final class CachePruner {
  CachePruner(
    this.host, {
    required this.engineRoot,
    required this.genSnapshotRoot,
    required this.inUseEngines,
    required this.olderThan,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final PlatformHostInterface host;

  /// Holds `<engine>/` iOS engine artifacts (`<cache>/xcross/flutter-engine`).
  final String engineRoot;

  /// Holds `<engine>/<mode>/<platform>/` compilers
  /// (`<cache>/xcross/gen-snapshot`, or under `XCROSS_CACHE_DIR`).
  final String genSnapshotRoot;
  final Set<String> inUseEngines;
  final Duration olderThan;
  final DateTime Function() _now;

  static final _engineRevision = RegExp(r'^[0-9a-f]{40}$');

  /// Every entry, kept or not, oldest first.
  List<CacheEntry> scan() {
    final entries = <CacheEntry>[
      for (final engine in _children(engineRoot))
        if (_engineRevision.hasMatch(_name(engine)))
          _entry(engine, 'flutter-engine', _name(engine)),
      for (final engine in _children(genSnapshotRoot))
        if (_engineRevision.hasMatch(_name(engine)))
          _entry(engine, 'gen-snapshot', _name(engine)),
    ]..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    return entries;
  }

  /// Removes stale entries, or only reports them when [dryRun] is set.
  Future<CachePruneResult> prune({bool dryRun = false}) async {
    final removed = <CacheEntry>[];
    final kept = <CacheEntry>[];
    final cutoff = _now().subtract(olderThan);
    for (final entry in scan()) {
      final stale =
          !inUseEngines.contains(entry.engine) &&
          entry.lastUsed.isBefore(cutoff);
      if (!stale) {
        kept.add(entry);
        continue;
      }
      if (!dryRun) {
        try {
          await host.fileSystem.directory(entry.path).delete(recursive: true);
        } on FileSystemException {
          kept.add(entry);
          continue;
        }
      }
      removed.add(entry);
    }
    return CachePruneResult(removed: removed, kept: kept);
  }

  CacheEntry _entry(Directory directory, String kind, String engine) {
    var bytes = 0;
    DateTime? stamped;
    void consider(DateTime? used) {
      if (used != null && (stamped == null || used.isAfter(stamped!))) {
        stamped = used;
      }
    }

    try {
      for (final entity in directory.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          bytes += entity.lengthSync();
        } on FileSystemException {
          continue;
        }
        if (_name(entity) == 'meta.json') {
          consider(_lastUsed(entity));
        } else if (_name(entity) == '.last_used') {
          consider(_stampedAt(entity));
        }
      }
    } on FileSystemException {
      // Partially unreadable entries are judged by what could be read.
    }
    return CacheEntry(
      path: directory.path,
      kind: kind,
      engine: engine,
      // A recorded use is authoritative; the directory time only stands in
      // for entries written before xcross recorded uses.
      lastUsed: stamped ?? _safeModified(directory),
      bytes: bytes,
    );
  }

  /// The `last_used` stamp the gen_snapshot resolver records on every hit.
  DateTime? _lastUsed(File meta) {
    try {
      final Object? decoded = jsonDecode(meta.readAsStringSync());
      if (decoded case {'last_used': final String stamp}) {
        return DateTime.tryParse(stamp);
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// The `.last_used` stamp the engine cache writes on every build.
  DateTime? _stampedAt(File stamp) {
    try {
      return DateTime.tryParse(stamp.readAsStringSync().trim());
    } on FileSystemException {
      return null;
    }
  }

  DateTime _safeModified(Directory directory) {
    try {
      return directory.statSync().modified;
    } on FileSystemException {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  Iterable<Directory> _children(String path) {
    final directory = host.fileSystem.directory(path);
    try {
      if (!directory.existsSync()) return const [];
      return directory.listSync(followLinks: false).whereType<Directory>();
    } on FileSystemException {
      return const [];
    }
  }

  String _name(FileSystemEntity entity) =>
      host.paths.context.basename(entity.path);
}
