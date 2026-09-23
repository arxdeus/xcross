import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

/// Covers the failure that turned a cold `flutter_example` CI build into a
/// multi-hour hang: reading symlink blobs out of a SwiftPM checkout wrote every
/// request into `git cat-file --batch` before reading any of its answers.
///
/// `cat-file --batch` streams a reply per request, so its stdout fills while
/// stdin is still being written. A pipe buffer is finite (64 KiB on Windows),
/// so once the replies outgrow it both sides block on each other forever: git
/// waits for someone to read its output, xcross waits for git to read its
/// input. Real checkouts with many symlinked headers (SDWebImage) cross that
/// line, and the build then produced no output and no error until the job died.
void main() {
  late Directory temp;
  late String git;

  setUpAll(() async => git = await ProcessRunner.locateTool('git'));
  setUp(() => temp = Directory.systemTemp.createTempSync('xcross-blobs-'));
  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can still hold a handle from the child; the temp dir is
      // disposable either way.
    }
  });

  /// A repository holding [count] blobs of [size] bytes each, returning their
  /// object IDs mapped to their contents.
  Future<Map<String, String>> repositoryWithBlobs({
    required int count,
    required int size,
  }) async {
    final root = Directory(p.join(temp.path, 'repo'))..createSync();
    await ProcessRunner.runChecked(git, ['-C', root.path, 'init', '--quiet']);
    final blobs = <String, String>{};
    for (var index = 0; index < count; index++) {
      // Distinct contents so each gets its own object ID, and so a reply
      // mismatched against its request cannot pass unnoticed.
      final content = '$index:${'x' * (size - '$index:'.length)}';
      final file = File(p.join(root.path, 'blob-$index'))
        ..writeAsStringSync(content);
      final hashed = await ProcessRunner.run(git, [
        '-C',
        root.path,
        'hash-object',
        '-w',
        file.path,
      ]);
      expect(hashed.exitCode, 0, reason: hashed.stderr);
      blobs[hashed.stdout.trim()] = content;
    }
    return blobs;
  }

  test('reads blobs whose total size far exceeds the pipe buffer', () async {
    // ~4 MiB of replies against a 64 KiB Windows pipe buffer: the old
    // write-then-read order deadlocked here every time.
    final expected = await repositoryWithBlobs(count: 64, size: 64 * 1024);

    final blobs = await GeneratedPluginsPackage.readGitBlobs(
      p.join(temp.path, 'repo'),
      expected.keys.toSet(),
      git,
    ).timeout(
      const Duration(minutes: 2),
      onTimeout: () => fail('readGitBlobs deadlocked on the stdout pipe'),
    );

    expect(blobs.keys.toSet(), expected.keys.toSet());
    for (final entry in expected.entries) {
      expect(utf8.decode(blobs[entry.key]!), entry.value);
    }
  });

  test('returns each requested blob verbatim', () async {
    final expected = await repositoryWithBlobs(count: 3, size: 64);

    final blobs = await GeneratedPluginsPackage.readGitBlobs(
      p.join(temp.path, 'repo'),
      expected.keys.toSet(),
      git,
    );

    for (final entry in expected.entries) {
      expect(utf8.decode(blobs[entry.key]!), entry.value);
    }
  });

  test('reports a missing object instead of hanging', () async {
    await repositoryWithBlobs(count: 1, size: 32);

    await expectLater(
      GeneratedPluginsPackage.readGitBlobs(p.join(temp.path, 'repo'), {
        '0' * 40,
      }, git),
      throwsA(isA<Exception>()),
    );
  });

  test('does nothing for an empty request', () async {
    expect(
      await GeneratedPluginsPackage.readGitBlobs(temp.path, const {}, git),
      isEmpty,
    );
  });
}
