import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/internal/swap_entry.dart';

/// Replaces installed files as one rollback-able unit.
///
/// Every replacement lands through a rename *inside* the destination
/// directory, so it is atomic and never crosses a filesystem boundary. The
/// previous file is renamed aside instead of being overwritten: that is the
/// only way to replace a running executable or a loaded DLL on Windows, and it
/// doubles as the rollback copy on every platform.
final class FileSwap {
  FileSwap({required this.useSudo});

  /// Whether each step has to run through `sudo` because the install
  /// directories belong to root.
  final bool useSudo;

  final _done = <SwapEntry>[];

  /// Files replaced so far, oldest first.
  List<SwapEntry> get entries => List.unmodifiable(_done);

  /// Marker shared by every parked file, so a later run can recognise and
  /// collect the ones Windows refused to delete while they were mapped.
  static const backupMarker = '.old-';

  /// Marker for a file staged in the destination directory but not yet moved
  /// onto its target.
  static const incomingMarker = '.new-';

  /// Copies [source] over [target], parking whatever was there.
  Future<void> replace({required String source, required String target}) async {
    final incoming = _sibling(target, '$incomingMarker$pid');
    await _copy(source, incoming);

    String? backup;
    try {
      if (File(target).existsSync()) {
        backup = _sibling(target, '$backupMarker$pid');
        await _move(target, backup);
      }
      try {
        await _move(incoming, target);
      } on Object {
        if (backup != null) await _move(backup, target);
        rethrow;
      }
    } on Object {
      // The staged copy is dead weight the sweep would otherwise inherit, and
      // in a root-owned install directory the user cannot remove it by hand.
      await _tryDelete(incoming);
      rethrow;
    }
    _done.add(SwapEntry(target: target, backup: backup));
  }

  static String _sibling(String target, String suffix) =>
      p.join(p.dirname(target), '.${p.basename(target)}$suffix');

  /// Restores every replaced file, newest first.
  ///
  /// Reports rather than throws: a rollback runs while another failure is
  /// already propagating, and losing that original error would hide the cause.
  Future<void> rollback() async {
    for (final entry in _done.reversed) {
      try {
        final backup = entry.backup;
        if (backup == null) {
          // Nothing was there before, so restoring means removing what this
          // run added.
          await _tryDelete(entry.target);
          continue;
        }
        if (!File(backup).existsSync()) {
          Log.logWarn(
            'could not restore ${entry.target}: backup $backup is missing',
          );
          continue;
        }
        // Windows refuses to replace a file the verification child may still
        // have mapped, but it always allows renaming it away first.
        await _tryMoveAside(entry.target);
        await _move(backup, entry.target);
      } on Object catch (e) {
        Log.logWarn('could not restore ${entry.target}: $e');
      }
    }
    _done.clear();
  }

  Future<void> _tryMoveAside(String target) async {
    if (!File(target).existsSync()) return;
    try {
      await _move(target, _sibling(target, '$backupMarker$pid-failed'));
    } on Object {
      Log.logTrace('could not park the failed $target');
    }
  }

  /// Drops the parked files once the swap is known good.
  ///
  /// Deleting one fails on Windows while this process still has it mapped;
  /// [sweepStaleBackups] finishes the job on a later run.
  Future<void> discardBackups() async {
    for (final entry in _done) {
      final backup = entry.backup;
      if (backup == null) continue;
      if (!await _tryDelete(backup)) {
        Log.logTrace('leaving $backup for a later sweep');
      }
    }
  }

  Future<bool> _tryDelete(String path) async {
    try {
      await _delete(path);
      return true;
    } on Object {
      return false;
    }
  }

  /// A parked file younger than this may belong to an update still running in
  /// another process, whose rollback would break if it disappeared.
  static const _minimumAge = Duration(minutes: 10);

  /// Best-effort removal of leftovers a previous update could not delete.
  static void sweepStaleBackups(Iterable<String> directories) {
    final now = DateTime.now();
    for (final directory in directories.toSet()) {
      try {
        for (final file in Directory(directory).listSync().whereType<File>()) {
          if (!_leftover.hasMatch(p.basename(file.path))) continue;
          try {
            if (now.difference(file.lastModifiedSync()) < _minimumAge) continue;
            file.deleteSync();
          } on FileSystemException {
            // Still held by another process; try again next time.
          }
        }
      } on FileSystemException {
        // An unreadable install directory is not this command's problem.
      }
    }
  }

  /// Anchored so it only ever matches the names [_sibling] generates: a
  /// `contains` test would also match unrelated files such as
  /// `libfoo.so.old-2024` sitting in a shared `/usr/local/lib`.
  static final _leftover = RegExp(
    '^\\..+(?:${RegExp.escape(backupMarker)}|'
    '${RegExp.escape(incomingMarker)})[0-9]+(?:-failed)?\$',
  );

  Future<void> _copy(String source, String target) async {
    if (!useSudo) {
      await File(source).copy(target);
      if (!Platform.isWindows) ProcessRunner.makeExecutable(target);
      return;
    }
    await _sudo(['install', '-m', '0755', source, target]);
  }

  Future<void> _move(String source, String target) async {
    if (!useSudo) {
      await File(source).rename(target);
      return;
    }
    await _sudo(['mv', '-f', source, target]);
  }

  Future<void> _delete(String path) async {
    if (!useSudo) {
      await File(path).delete();
      return;
    }
    await _sudo(['rm', '-f', path]);
  }

  /// `-n` matters: these run mid-swap with captured stdio, so a `sudo` that
  /// decided to prompt would block forever on a pipe nobody is reading, with
  /// the old binary already renamed aside.
  static Future<void> _sudo(List<String> arguments) async {
    final sudo = await Sudo.resolve();
    if (sudo == null) {
      throw XcrossError(
        'sudo is required to write the install directory but was not found',
      );
    }
    await ProcessRunner.runChecked(sudo, ['-n', ...arguments], label: 'update');
  }
}
