import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/update/internal/file_swap.dart';

void main() {
  late Directory root;
  late Directory staged;
  late Directory installed;

  File stagedFile(String name, String contents) =>
      File(p.join(staged.path, name))..writeAsStringSync(contents);

  String target(String name) => p.join(installed.path, name);

  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-swap-');
    staged = Directory(p.join(root.path, 'staged'))..createSync();
    installed = Directory(p.join(root.path, 'installed'))..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('replaces an existing file and parks the previous one', () async {
    File(target('xcross')).writeAsStringSync('old');
    stagedFile('xcross', 'new');

    final swap = FileSwap(useSudo: false);
    await swap.replace(
      source: p.join(staged.path, 'xcross'),
      target: target('xcross'),
    );

    expect(File(target('xcross')).readAsStringSync(), 'new');
    expect(swap.entries, hasLength(1));
    expect(swap.entries.single.backup, isNotNull);
    expect(File(swap.entries.single.backup!).readAsStringSync(), 'old');
  });

  test('installs a file that was not there before', () async {
    stagedFile('libnew.so', 'fresh');

    final swap = FileSwap(useSudo: false);
    await swap.replace(
      source: p.join(staged.path, 'libnew.so'),
      target: target('libnew.so'),
    );

    expect(File(target('libnew.so')).readAsStringSync(), 'fresh');
    expect(swap.entries.single.backup, isNull);
  });

  test('rollback restores every replaced file, newest first', () async {
    File(target('xcross')).writeAsStringSync('old-bin');
    File(target('libx.so')).writeAsStringSync('old-lib');
    stagedFile('xcross', 'new-bin');
    stagedFile('libx.so', 'new-lib');

    final swap = FileSwap(useSudo: false);
    await swap.replace(
      source: p.join(staged.path, 'xcross'),
      target: target('xcross'),
    );
    await swap.replace(
      source: p.join(staged.path, 'libx.so'),
      target: target('libx.so'),
    );
    expect(File(target('xcross')).readAsStringSync(), 'new-bin');

    await swap.rollback();

    expect(File(target('xcross')).readAsStringSync(), 'old-bin');
    expect(File(target('libx.so')).readAsStringSync(), 'old-lib');
    expect(swap.entries, isEmpty);
  });

  test('a successful swap leaves only the installed files behind', () async {
    File(target('xcross')).writeAsStringSync('old');
    stagedFile('xcross', 'new');

    final swap = FileSwap(useSudo: false);
    await swap.replace(
      source: p.join(staged.path, 'xcross'),
      target: target('xcross'),
    );
    await swap.discardBackups();

    expect(installed.listSync().map((e) => p.basename(e.path)), [
      'xcross',
    ], reason: 'no .new- or .old- leftovers');
  });

  test('rollback removes a file the update newly added', () async {
    stagedFile('libnew.so', 'fresh');

    final swap = FileSwap(useSudo: false);
    await swap.replace(
      source: p.join(staged.path, 'libnew.so'),
      target: target('libnew.so'),
    );
    await swap.rollback();

    expect(File(target('libnew.so')).existsSync(), isFalse);
    expect(installed.listSync(), isEmpty);
  });

  test('a failed replace leaves no staged file behind', () async {
    // A directory where the incoming file wants to be makes the rename fail
    // after the copy has already landed.
    stagedFile('xcross', 'new');
    Directory(target('xcross')).createSync();

    final swap = FileSwap(useSudo: false);
    await expectLater(
      swap.replace(
        source: p.join(staged.path, 'xcross'),
        target: target('xcross'),
      ),
      throwsA(isA<Object>()),
    );

    expect(
      installed
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.contains(FileSwap.incomingMarker)),
      isEmpty,
    );
  });

  test('sweepStaleBackups collects what a previous run could not', () {
    final stale = File(
      p.join(installed.path, '.xcross${FileSwap.backupMarker}999'),
    )..writeAsStringSync('stale');
    stale.setLastModifiedSync(
      DateTime.now().subtract(const Duration(hours: 2)),
    );
    File(target('xcross')).writeAsStringSync('current');

    FileSwap.sweepStaleBackups([installed.path]);

    expect(installed.listSync().map((e) => p.basename(e.path)), ['xcross']);
  });

  // A backup this young may belong to an update running right now in another
  // process, whose rollback still needs it.
  test('sweepStaleBackups spares a freshly parked backup', () {
    File(
      p.join(installed.path, '.xcross${FileSwap.backupMarker}999'),
    ).writeAsStringSync('in flight');

    FileSwap.sweepStaleBackups([installed.path]);

    expect(installed.listSync(), hasLength(1));
  });

  // A bare `contains('.old-')` test would delete unrelated files that happen
  // to sit in a shared /usr/local/lib.
  test('sweepStaleBackups spares unrelated files', () {
    final bystanders = [
      'libfoo.so.old-2024',
      'backup.old-copy',
      'xcross',
      '.hidden',
    ];
    for (final name in bystanders) {
      final file = File(p.join(installed.path, name))
        ..writeAsStringSync('keep');
      file.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 30)),
      );
    }

    FileSwap.sweepStaleBackups([installed.path]);

    expect(
      installed.listSync().map((e) => p.basename(e.path)).toSet(),
      bystanders.toSet(),
    );
  });

  test('sweepStaleBackups ignores a directory that does not exist', () {
    FileSwap.sweepStaleBackups([p.join(root.path, 'missing')]);
  });
}
