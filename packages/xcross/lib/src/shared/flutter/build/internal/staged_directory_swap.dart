import 'dart:io';
import 'dart:math';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';

/// Renames [source] to [destination]. Injectable so tests can simulate a
/// locked file (Windows antivirus or indexer).
@internal
typedef DirectoryRenamer =
    Future<void> Function(Directory source, String destination);

/// Builds a directory next to its destination (same volume) and swaps it in
/// with a rename, so a finished bundle is never copied a second time and the
/// destination only changes once the new contents are complete.
@internal
final class StagedDirectorySwap {
  StagedDirectorySwap({
    required this.fileSystem,
    required this.paths,
    required this.copier,
    DirectoryRenamer? rename,
    this.retryDelays = const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 200),
      Duration(milliseconds: 500),
      Duration(seconds: 1),
    ],
    Random? random,
  }) : _rename =
           rename ?? ((source, destination) => source.rename(destination)),
       _random = random ?? Random();

  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final RecursiveDirectoryCopier copier;

  /// Pauses between rename attempts. A rename that still fails after the
  /// last one falls back to copy plus delete.
  final List<Duration> retryDelays;
  final DirectoryRenamer _rename;
  final Random _random;

  /// Prefix shared by staging and backup directories of [destination].
  String _prefix(String destination) => '.${paths.basename(destination)}.';

  /// Removes staging and backup directories a crashed earlier run left beside
  /// [destination], then creates a fresh staging container there and returns
  /// the not yet existing `<container>/<basename of destination>` to build in,
  /// so the staged directory keeps its real name (codesign, logs).
  Future<Directory> createStaging(String destination) async {
    final parent = fileSystem.directory(paths.dirname(destination));
    await parent.create(recursive: true);
    await cleanStale(destination);
    final suffix = _random.nextInt(1 << 32).toRadixString(16);
    final staging = fileSystem.directory(
      paths.join(parent.path, '${_prefix(destination)}staging-$suffix'),
    );
    await staging.create();
    return fileSystem.directory(
      paths.join(staging.path, paths.basename(destination)),
    );
  }

  /// Deletes `.<name>.staging-*` and `.<name>.old-*` beside [destination].
  Future<void> cleanStale(String destination) async {
    final parent = fileSystem.directory(paths.dirname(destination));
    if (!parent.existsSync()) return;
    final prefix = _prefix(destination);
    await for (final entity in parent.list(followLinks: false)) {
      final name = paths.basename(entity.path);
      if (!name.startsWith(prefix)) continue;
      final rest = name.substring(prefix.length);
      if (!rest.startsWith('staging-') && !rest.startsWith('old-')) continue;
      await _deleteQuietly(entity);
    }
  }

  /// Deletes the container of a [staging] directory from [createStaging].
  Future<void> discard(Directory staging) =>
      _deleteQuietly(fileSystem.directory(paths.dirname(staging.path)));

  /// Moves [staging] (from [createStaging]) into place at [destination]. An existing destination is
  /// renamed aside first (so the window without an app is one rename), then
  /// deleted. When renames keep failing the staging contents are copied
  /// instead.
  Future<void> swap(Directory staging, String destination) async {
    final dest = fileSystem.directory(destination);
    Directory? old;
    if (dest.existsSync()) {
      final oldPath = paths.join(
        paths.dirname(destination),
        '${_prefix(destination)}old-'
        '${_random.nextInt(1 << 32).toRadixString(16)}',
      );
      if (await _tryRename(dest, oldPath)) {
        old = fileSystem.directory(oldPath);
      } else {
        await dest.delete(recursive: true);
      }
    }
    if (!await _tryRename(staging, destination)) {
      await copier.copy(staging.path, destination);
    }
    await discard(staging);
    if (old != null) await _deleteQuietly(old);
  }

  Future<bool> _tryRename(Directory source, String destination) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await _rename(source, destination);
        return true;
      } on FileSystemException {
        if (attempt >= retryDelays.length) return false;
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      await entity.delete(recursive: true);
    } on FileSystemException {
      // A leftover is removed by the next run's cleanStale.
    }
  }
}
