import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

@internal
final class SwiftPmGitRepository<T extends PlatformHostInterface> {
  SwiftPmGitRepository({
    required this.runner,
    required this.fileSystem,
    required this.filesystem,
  });
  final ProcessRunner<T> runner;
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmFilesystem<T> filesystem;
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
}
