import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/git_update_ref_resolver.dart';
import 'package:xcross/src/update/internal/dart_executable_resolver.dart';
import 'package:xcross/src/update/internal/update_process.dart';
import 'package:xcross/src/update/update_progress.dart';

typedef TempDirectoryModifiedAt = DateTime Function(Directory directory);
typedef DartExecutableLocator = Future<String> Function();

final class GitRefSourceBundleBuilder {
  GitRefSourceBundleBuilder({
    RunGitProcess? run,
    CreateTempDirectory? createTempDirectory,
    DeleteDirectory? deleteDirectory,
    Directory? systemTempDirectory,
    TempDirectoryModifiedAt? tempDirectoryModifiedAt,
    DartExecutableLocator? resolveDartExecutable,
  }) : _run = run ?? runUpdateProcess,
       _createTempDirectory =
           createTempDirectory ?? _defaultCreateTempDirectory,
       _deleteDirectory = deleteDirectory ?? _defaultDeleteDirectory,
       _systemTempDirectory = systemTempDirectory ?? Directory.systemTemp,
       _tempDirectoryModifiedAt =
           tempDirectoryModifiedAt ?? _defaultTempDirectoryModifiedAt,
       _resolveDartExecutable =
           resolveDartExecutable ?? findDartExecutableOnPath;

  static const repoUrl = GitUpdateRefResolver.repoUrl;

  final RunGitProcess _run;
  final CreateTempDirectory _createTempDirectory;
  final DeleteDirectory _deleteDirectory;
  final Directory _systemTempDirectory;
  final TempDirectoryModifiedAt _tempDirectoryModifiedAt;
  final DartExecutableLocator _resolveDartExecutable;

  static const _tempDirectoryPrefix = 'xcross-update-source-';
  static const _minimumStaleAge = Duration(minutes: 10);

  Future<T> build<T>({
    required GitUpdateRef ref,
    required Future<T> Function(Directory bundle, UpdateProgress progress)
    onBundle,
  }) async {
    if (ref.kind == GitUpdateRefKind.tag) {
      throw XcrossError(
        'build updates from source only supports non-tag git update refs',
      );
    }

    await _deleteStaleTempDirectories();
    final tempDirectory = await _createTempDirectory(_tempDirectoryPrefix);
    final progress = UpdateProgress('Source', UpdatePhases.source.length);
    try {
      final repoDirectory = Directory(p.join(tempDirectory.path, 'xcross'));
      await progress.run(
        'Clone repository',
        () => _runChecked('git', [
          'clone',
          repoUrl,
          repoDirectory.path,
        ], action: 'clone update source'),
      );
      await progress.run(
        'Fetch commit',
        () => _runChecked(
          'git',
          ['fetch', '--depth', '1', 'origin', ref.commitSha],
          workingDirectory: repoDirectory.path,
          action: 'fetch update commit ${ref.commitSha}',
        ),
      );
      await progress.run(
        'Check out commit',
        () => _runChecked(
          'git',
          ['checkout', '--detach', ref.commitSha],
          workingDirectory: repoDirectory.path,
          action: 'checkout update commit ${ref.commitSha}',
        ),
      );
      final dartExecutable = await _resolveDartExecutable();
      await progress.run(
        'Resolve dependencies',
        () => _runChecked(
          dartExecutable,
          ['pub', 'get'],
          workingDirectory: repoDirectory.path,
          action: 'run dart pub get for update source',
        ),
      );
      final packageDirectory = Directory(
        p.join(repoDirectory.path, 'packages', 'xcross'),
      );
      final encodedVersion = Uri.encodeComponent(ref.displayName);
      await progress.run(
        'Build xcross ${ref.displayName}',
        () => _runChecked(
          dartExecutable,
          [
            'run',
            '-DXCROSS_VERSION=$encodedVersion',
            '-DXCROSS_RELEASED=false',
            'tool/build_xcross.dart',
          ],
          workingDirectory: packageDirectory.path,
          action: 'build update bundle',
        ),
      );
      return await onBundle(_findBundle(packageDirectory), progress);
    } finally {
      try {
        await _deleteDirectory(tempDirectory);
      } on Object {
        // Best effort cleanup. The bundle result or original failure still wins.
      }
    }
  }

  Directory _findBundle(Directory packageDirectory) {
    final buildCliDirectory = Directory(
      p.join(packageDirectory.path, 'build', 'cli'),
    );
    final matches = <Directory>[];
    if (buildCliDirectory.existsSync()) {
      for (final entry in buildCliDirectory.listSync(followLinks: false)) {
        if (entry is! Directory) continue;
        final bundle = Directory(p.join(entry.path, 'bundle'));
        if (!bundle.existsSync()) continue;
        if (!Directory(p.join(bundle.path, 'bin')).existsSync()) continue;
        if (!Directory(p.join(bundle.path, 'lib')).existsSync()) continue;
        matches.add(bundle);
      }
    }
    if (matches.length != 1) {
      throw XcrossError(
        'expected exactly one built update bundle under ${buildCliDirectory.path}, found ${matches.length}',
      );
    }
    return matches.single;
  }

  Future<void> _runChecked(
    String executable,
    List<String> arguments, {
    required String action,
    String? workingDirectory,
  }) async {
    final result = await _run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode == 0) return;
    final stderr = '${result.stderr}'.trim();
    throw XcrossError(
      stderr.isEmpty ? 'failed to $action' : 'failed to $action: $stderr',
    );
  }

  Future<void> _deleteStaleTempDirectories() async {
    final now = DateTime.now();
    try {
      await for (final entry in _systemTempDirectory.list(followLinks: false)) {
        if (entry is! Directory ||
            !p.basename(entry.path).startsWith(_tempDirectoryPrefix)) {
          continue;
        }
        try {
          final modifiedAt = _tempDirectoryModifiedAt(entry);
          if (now.difference(modifiedAt) < _minimumStaleAge) continue;
          await entry.delete(recursive: true);
        } on Object {
          continue;
        }
      }
    } on Object {
      return;
    }
  }

  static DateTime _defaultTempDirectoryModifiedAt(Directory directory) =>
      directory.statSync().modified;

  static Future<Directory> _defaultCreateTempDirectory(String prefix) =>
      Directory.systemTemp.createTemp(prefix);

  static Future<void> _defaultDeleteDirectory(Directory directory) =>
      directory.delete(recursive: true);
}
