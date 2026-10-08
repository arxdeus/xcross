import 'dart:io';

import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/git_update_ref_resolver.dart';
import 'package:xcross/src/shared/update/internal/dart_executable_resolver.dart';
import 'package:xcross/src/shared/update/internal/update_process.dart';
import 'package:xcross/src/shared/update/update_progress.dart';

@internal
typedef TempDirectoryModifiedAt = DateTime Function(Directory directory);
@internal
typedef DartExecutableLocator = Future<String> Function();

@internal
final class GitRefSourceBundleBuilder {
  GitRefSourceBundleBuilder({
    required this.runner,
    required bool Function(String) acceptDartLauncher,
    RunGitProcess? run,
    CreateTempDirectory? createTempDirectory,
    DeleteDirectory? deleteDirectory,
    Directory? systemTempDirectory,
    TempDirectoryModifiedAt? tempDirectoryModifiedAt,
    DartExecutableLocator? resolveDartExecutable,
  }) : _usesSelectedTemporaryRoot = systemTempDirectory == null,
       _run =
           run ??
           ((executable, arguments, {workingDirectory}) => runUpdateProcess(
             runner,
             executable,
             arguments,
             workingDirectory: workingDirectory,
           )),
       _createTempDirectory =
           createTempDirectory ??
           ((prefix) => runner.host.fileSystem
               .directory(runner.host.paths.temporaryRoot)
               .createTemp(prefix)),
       _deleteDirectory = deleteDirectory ?? _defaultDeleteDirectory,
       _systemTempDirectory =
           systemTempDirectory ??
           runner.host.fileSystem.directory(runner.host.paths.temporaryRoot),
       _tempDirectoryModifiedAt =
           tempDirectoryModifiedAt ?? _defaultTempDirectoryModifiedAt,
       _resolveDartExecutable =
           resolveDartExecutable ??
           (() => findDartExecutableOnPath(
             runner: runner,
             acceptLauncher: acceptDartLauncher,
           ));

  static const repoUrl = GitUpdateRefResolver.repoUrl;

  final ProcessRunner runner;
  final RunGitProcess _run;
  final CreateTempDirectory _createTempDirectory;
  final DeleteDirectory _deleteDirectory;
  final Directory _systemTempDirectory;
  final bool _usesSelectedTemporaryRoot;
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

    final dartExecutable = await _resolveDartExecutable();
    await _deleteStaleTempDirectories();
    final tempDirectory = await _createTempDirectory(_tempDirectoryPrefix);
    final progress = UpdateProgress(
      'Source',
      UpdatePhases.source.length,
      log: runner.log,
    );
    try {
      final paths = runner.host.paths.context;
      final tempPath =
          _usesSelectedTemporaryRoot &&
              paths.isWithin(_systemTempDirectory.path, tempDirectory.path)
          ? paths.join(
              runner.host.paths.temporaryRoot,
              paths.relative(
                tempDirectory.path,
                from: _systemTempDirectory.path,
              ),
            )
          : tempDirectory.path;
      final repoPath = paths.join(tempPath, 'xcross');
      await progress.run(
        'Clone repository',
        () => _runChecked('git', [
          'clone',
          repoUrl,
          runner.host.fileSystem.directory(repoPath).path,
        ], action: 'clone update source'),
      );
      await progress.run(
        'Fetch commit',
        () => _runChecked(
          'git',
          ['fetch', '--depth', '1', 'origin', ref.commitSha],
          workingDirectory: repoPath,
          action: 'fetch update commit ${ref.commitSha}',
        ),
      );
      await progress.run(
        'Check out commit',
        () => _runChecked(
          'git',
          ['checkout', '--detach', ref.commitSha],
          workingDirectory: repoPath,
          action: 'checkout update commit ${ref.commitSha}',
        ),
      );
      await progress.run(
        'Resolve dependencies',
        () => _runChecked(
          dartExecutable,
          ['pub', 'get'],
          workingDirectory: repoPath,
          action: 'run dart pub get for update source',
        ),
      );
      final packagePath = paths.join(repoPath, 'packages', 'xcross');
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
          workingDirectory: packagePath,
          action: 'build update bundle',
        ),
      );
      return await onBundle(_findBundle(packagePath), progress);
    } finally {
      try {
        await _deleteDirectory(tempDirectory);
      } on Object {
        // Best effort cleanup. The bundle result or original failure still wins.
      }
    }
  }

  Directory _findBundle(String packagePath) {
    final bundlePath = runner.host.paths.context.join(
      packagePath,
      'build',
      'cli',
      '${runner.host.name}_${runner.host.architecture}',
      'bundle',
    );
    final bundle = runner.host.fileSystem.directory(bundlePath);
    if (!bundle.existsSync() ||
        !runner.host.fileSystem
            .directory(runner.host.paths.context.join(bundlePath, 'bin'))
            .existsSync() ||
        !runner.host.fileSystem
            .directory(runner.host.paths.context.join(bundlePath, 'lib'))
            .existsSync()) {
      throw XcrossError('expected built update bundle at ${bundle.path}');
    }
    return bundle;
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
            !runner.host.paths.context
                .basename(entry.path)
                .startsWith(_tempDirectoryPrefix)) {
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

  static Future<void> _defaultDeleteDirectory(Directory directory) =>
      directory.delete(recursive: true);
}
