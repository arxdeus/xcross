@TestOn('!windows')
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/shared/ipa_packager.dart';

/// Deterministic, non-repeating byte content — long enough that a truncated
/// or reordered copy would fail the equality check.
List<int> _bytesFrom(int seed, int length) =>
    List<int>.generate(length, (i) => (i * seed + seed) % 256);

void main() {
  late Directory tmp;
  late String appPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_ipa_packager-');
    appPath = p.join(tmp.path, 'MyApp.app');
    await Directory(appPath).create(recursive: true);
  });

  tearDown(() => tmp.delete(recursive: true));

  test('packages top-level and nested files under Payload/<app>/... with '
      'forward-slash entry names and byte-exact content', () async {
    final infoPlistBytes = _bytesFrom(3, 256);
    final flutterBinBytes = _bytesFrom(7, 512);

    await File(p.join(appPath, 'Info.plist')).writeAsBytes(infoPlistBytes);
    await Directory(
      p.join(appPath, 'Frameworks', 'Flutter.framework'),
    ).create(recursive: true);
    await File(
      p.join(appPath, 'Frameworks', 'Flutter.framework', 'Flutter'),
    ).writeAsBytes(flutterBinBytes);

    final ipaPath = await IpaPackager(host: LinuxHost()).package(appPath);

    expect(ipaPath, p.join(tmp.path, 'MyApp.ipa'));
    expect(File(ipaPath).existsSync(), isTrue);

    final archive = ZipDecoder().decodeBytes(await File(ipaPath).readAsBytes());
    expect(archive.files, hasLength(2));

    final plistEntry = archive.files.firstWhere(
      (f) => f.name == 'Payload/MyApp.app/Info.plist',
    );
    expect(plistEntry.content, equals(infoPlistBytes));

    final flutterEntry = archive.files.firstWhere(
      (f) =>
          f.name ==
          'Payload/MyApp.app/Frameworks/Flutter.framework/'
              'Flutter',
    );
    expect(flutterEntry.content, equals(flutterBinBytes));
  });

  // Regression check: package() must delete/replace the previous .ipa
  // wholesale rather than merge into it, otherwise a shrinking file set
  // would leave stale entries from an earlier run.
  test('a second package() call reflects only the current file contents, not '
      'a mix of the previous run', () async {
    final filePath = p.join(appPath, 'Data.bin');
    await File(filePath).writeAsBytes(_bytesFrom(1, 64));
    await IpaPackager(host: LinuxHost()).package(appPath);

    final updatedBytes = _bytesFrom(9, 96);
    await File(filePath).writeAsBytes(updatedBytes);
    final ipaPath = await IpaPackager(host: LinuxHost()).package(appPath);

    final archive = ZipDecoder().decodeBytes(await File(ipaPath).readAsBytes());
    expect(archive.files, hasLength(1));
    expect(archive.files.single.content, equals(updatedBytes));
  });

  test('an empty subdirectory emits no entry and does not stop packaging of '
      'files that do exist', () async {
    final keptBytes = _bytesFrom(5, 32);
    await File(p.join(appPath, 'Kept.txt')).writeAsBytes(keptBytes);
    await Directory(p.join(appPath, 'Empty')).create(recursive: true);

    final ipaPath = await IpaPackager(host: LinuxHost()).package(appPath);

    final archive = ZipDecoder().decodeBytes(await File(ipaPath).readAsBytes());
    expect(archive.files, hasLength(1));
    expect(archive.files.single.name, 'Payload/MyApp.app/Kept.txt');
    expect(archive.files.single.content, equals(keptBytes));
  });

  // Regression check for the mode-masking line (`mode & 0xFFF`): a mode
  // value that overflowed 12 bits would corrupt the packed zip external
  // attributes field, so it must always round-trip within 0..0xFFF.
  test('each entry mode is masked to 12 bits (0..0xFFF)', () async {
    await File(p.join(appPath, 'File.txt')).writeAsBytes(_bytesFrom(2, 8));

    final ipaPath = await IpaPackager(host: LinuxHost()).package(appPath);

    final archive = ZipDecoder().decodeBytes(await File(ipaPath).readAsBytes());
    final mode = archive.files.single.mode;
    expect(mode, inInclusiveRange(0, 0xFFF));
  });

  test(
    'an .app with no files at all still produces a valid, empty archive',
    () async {
      await Directory(p.join(appPath, 'Empty')).create(recursive: true);

      final ipaPath = await IpaPackager(host: LinuxHost()).package(appPath);

      final archive = ZipDecoder().decodeBytes(
        await File(ipaPath).readAsBytes(),
      );
      expect(archive.files, isEmpty);
    },
  );

  test('symlinks are followed: the entry holds the real target bytes, not a '
      'link marker', () async {
    final realBytes = _bytesFrom(11, 48);
    final realPath = p.join(appPath, 'Real.bin');
    await File(realPath).writeAsBytes(realBytes);
    final linkPath = p.join(appPath, 'Link.bin');

    try {
      Link(linkPath).createSync(realPath);
    } on FileSystemException {
      markTestSkipped('symlink creation unsupported in this environment');
      return;
    }

    final ipaPath = await IpaPackager(host: LinuxHost()).package(appPath);

    final archive = ZipDecoder().decodeBytes(await File(ipaPath).readAsBytes());
    final linkEntry = archive.files.firstWhere(
      (f) => f.name == 'Payload/MyApp.app/Link.bin',
    );
    expect(linkEntry.content, equals(realBytes));
  });

  test(
    'streams a large app: sorted entries, byte-identical round trip',
    () async {
      final expected = <String, List<int>>{};
      for (var d = 0; d < 8; d++) {
        for (var f = 0; f < 16; f++) {
          final rel = p.join('Dir$d', 'file$f.bin');
          // ~1 MB per file at the largest, ~40 MB total.
          final bytes = _bytesFrom(d * 16 + f + 1, 1 << (14 + (f % 7)));
          await File(p.join(appPath, rel)).create(recursive: true);
          await File(p.join(appPath, rel)).writeAsBytes(bytes);
          expected['Payload/MyApp.app/Dir$d/file$f.bin'] = bytes;
        }
      }

      final ipaPath = await IpaPackager(host: LinuxHost()).package(appPath);
      final archive = ZipDecoder().decodeStream(InputFileStream(ipaPath));
      final names = [for (final f in archive.files) f.name];
      expect(names, [...names]..sort());
      expect(names.toSet(), expected.keys.toSet());
      for (final file in archive.files) {
        expect(file.content, equals(expected[file.name]), reason: file.name);
      }
    },
  );
}
