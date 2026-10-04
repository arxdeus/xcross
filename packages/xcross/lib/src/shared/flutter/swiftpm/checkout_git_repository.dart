import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

abstract interface class SwiftPmGitPackageCloner {
  Future<void> cloneGitPackage(
    String git,
    String url,
    String ref,
    String destination,
  );
}

final class SwiftPmGitRepository<T extends PlatformHostInterface>
    implements SwiftPmGitPackageCloner {
  SwiftPmGitRepository({
    required this.runner,
    required this.fileSystem,
    required this.filesystem,
    required this.policy,
    required Map<String, String> environment,
  }) : environment = Map.unmodifiable(environment);
  final ProcessRunner<T> runner;
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmCheckoutGitPolicy policy;
  final Map<String, String> environment;
  String? gitHeadIdentity(String root) {
    var gitDir = p.join(root, '.git');
    if (fileSystem.typeSync(gitDir) == FileSystemEntityType.file) {
      final pointer = fileSystem.file(gitDir).readAsStringSync().trim();
      if (!pointer.startsWith('gitdir:')) return null;
      gitDir = p.normalize(
        p.absolute(root, pointer.substring('gitdir:'.length).trim()),
      );
    }
    final headFile = fileSystem.file(p.join(gitDir, 'HEAD'));
    if (!headFile.existsSync()) return null;
    final head = headFile.readAsStringSync().trim();
    if (!head.startsWith('ref:')) return head;
    final ref = head.substring('ref:'.length).trim();
    final commonDirFile = fileSystem.file(p.join(gitDir, 'commondir'));
    final commonDir = commonDirFile.existsSync()
        ? p.normalize(
            p.absolute(gitDir, commonDirFile.readAsStringSync().trim()),
          )
        : gitDir;
    for (final dir in {gitDir, commonDir}) {
      final refFile = fileSystem.file(p.join(dir, ref));
      if (refFile.existsSync()) return '$head\n${refFile.readAsStringSync()}';
    }
    final packed = fileSystem.file(p.join(commonDir, 'packed-refs'));
    if (packed.existsSync()) {
      for (final line in packed.readAsLinesSync()) {
        if (line.endsWith(' $ref')) return '$head\n$line';
      }
    }
    return null;
  }

  Future<Map<String, List<int>>> readGitBlobs(
    String repoPath,
    Set<String> objectIds,
    String git,
  ) async {
    if (objectIds.isEmpty) return const {};
    final process = await runner.start(git, [
      '-C',
      repoPath,
      'cat-file',
      '--batch',
    ]);
    final outputFuture = process.stdout.fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    final errorFuture = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    const timeout = Duration(minutes: 5);
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      unawaited(runner.killTree(process));
    });
    final List<int> output;
    final String error;
    final int exitCode;
    try {
      for (final objectId in objectIds) {
        process.stdin.writeln(objectId);
      }
      try {
        await process.stdin.flush();
        await process.stdin.close();
      } on Object catch (_) {}
      exitCode = await process.exitCode;
      output = await outputFuture;
      error = await errorFuture;
    } finally {
      timer.cancel();
    }
    if (timedOut) {
      throw FlutterBuildError(
        'Timed out after ${timeout.inMinutes} minutes reading symlink targets '
        'in SwiftPM checkout $repoPath.',
      );
    }
    if (exitCode != 0) {
      throw FlutterBuildError(
        'Could not read symlink targets in SwiftPM checkout $repoPath: $error',
      );
    }

    var offset = 0;
    final blobs = <String, List<int>>{};
    for (final requested in objectIds) {
      final newline = output.indexOf(10, offset);
      if (newline < 0) {
        throw FlutterBuildError(
          'Malformed Git object response in SwiftPM checkout $repoPath.',
        );
      }
      final header = utf8.decode(output.sublist(offset, newline));
      final fields = header.split(' ');
      if (fields.length != 3 || fields[1] != 'blob') {
        throw FlutterBuildError(
          'Could not read symlink target $requested in SwiftPM checkout '
          '$repoPath: $header',
        );
      }
      final size = int.tryParse(fields[2]);
      if (size == null || size < 0 || newline + 1 + size >= output.length) {
        throw FlutterBuildError(
          'Malformed Git object response in SwiftPM checkout $repoPath.',
        );
      }
      final end = newline + 1 + size;
      blobs[requested] = output.sublist(newline + 1, end);
      if (output[end] != 10) {
        throw FlutterBuildError(
          'Malformed Git object response in SwiftPM checkout $repoPath.',
        );
      }
      offset = end + 1;
    }
    return blobs;
  }

  @override
  Future<void> cloneGitPackage(
    String git,
    String url,
    String ref,
    String destination,
  ) async {
    final destDir = fileSystem.directory(destination);
    const timeout = Duration(minutes: 10);
    final gitConfig = await policy.cloneConfiguration();
    Future<void> updateSubmodules() async {
      if (!fileSystem.file(p.join(destination, '.gitmodules')).existsSync()) {
        return;
      }
      await runner.runChecked(
        git,
        [
          ...gitConfig,
          '-C',
          destination,
          'submodule',
          'update',
          '--init',
          '--recursive',
          '--depth',
          '1',
        ],
        environment: environment,
        timeout: timeout,
        label: 'git submodule update ${p.basename(destination)}',
      );
    }

    if (fileSystem.file(p.join(destination, '.git')).existsSync() ||
        fileSystem.directory(p.join(destination, '.git')).existsSync()) {
      final head = await runner.run(
        git,
        [...gitConfig, '-C', destination, 'rev-parse', '--verify', 'HEAD'],
        environment: environment,
        timeout: timeout,
      );
      if (head.exitCode == 0 &&
          head.stdout.trim().toLowerCase() == ref.toLowerCase()) {
        await runner.runChecked(
          git,
          [...gitConfig, '-C', destination, 'reset', '--hard', 'HEAD'],
          environment: environment,
          timeout: timeout,
          label: 'git reset vendored package',
        );
        await updateSubmodules();
        return;
      }
    }
    await filesystem.deleteEntity(destination);
    await destDir.parent.create(recursive: true);

    final shallow = await runner.run(
      git,
      [
        ...gitConfig,
        'clone',
        '--depth',
        '1',
        '--branch',
        ref,
        url,
        destination,
      ],
      environment: environment,
      timeout: timeout,
    );
    if (shallow.exitCode == 0) {
      await updateSubmodules();
      return;
    }

    await filesystem.deleteEntity(destination);
    await fileSystem.directory(destination).create(recursive: true);
    final init = await runner.run(
      git,
      [...gitConfig, '-C', destination, 'init'],
      environment: environment,
      timeout: timeout,
    );
    final fetch = init.exitCode == 0
        ? await runner.run(
            git,
            [
              ...gitConfig,
              '-C',
              destination,
              'fetch',
              '--depth',
              '1',
              url,
              ref,
            ],
            environment: environment,
            timeout: timeout,
          )
        : init;
    final checkout = fetch.exitCode == 0
        ? await runner.run(
            git,
            [
              ...gitConfig,
              '-C',
              destination,
              'checkout',
              '--detach',
              'FETCH_HEAD',
            ],
            environment: environment,
            timeout: timeout,
          )
        : fetch;
    if (checkout.exitCode == 0) {
      await updateSubmodules();
      return;
    }

    await filesystem.deleteEntity(destination);
    await runner.runChecked(
      git,
      [...gitConfig, 'clone', url, destination],
      environment: environment,
      timeout: timeout,
      label: 'git clone $url',
    );
    await runner.runChecked(
      git,
      [...gitConfig, '-C', destination, 'checkout', ref],
      environment: environment,
      timeout: timeout,
      label: 'git checkout $ref',
    );
    await updateSubmodules();
  }
}
