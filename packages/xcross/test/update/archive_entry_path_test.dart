import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/update/internal/archive_entry_path.dart';

void main() {
  group('sanitize', () {
    test('keeps the payload entries a release archive really has', () {
      expect(ArchiveEntryPath.sanitize('bin/xcross'), 'bin/xcross');
      expect(
        ArchiveEntryPath.sanitize('lib/sysv_abi_bridge.dll'),
        'lib/sysv_abi_bridge.dll',
      );
      expect(ArchiveEntryPath.sanitize(r'bin\xcross.exe'), 'bin/xcross.exe');
      expect(ArchiveEntryPath.sanitize('./bin/xcross'), 'bin/xcross');
      expect(ArchiveEntryPath.sanitize('bin//xcross'), 'bin/xcross');
    });

    test('rejects every way out of the destination', () {
      for (final hostile in [
        '',
        '   ',
        '..',
        '../etc/passwd',
        'bin/../../etc/passwd',
        '/etc/passwd',
        r'\etc\passwd',
        r'C:\Windows\System32\evil.dll',
        r'..\..\windows\system32\evil.dll',
        './',
      ]) {
        expect(
          ArchiveEntryPath.sanitize(hostile),
          isNull,
          reason: 'expected "$hostile" to be refused',
        );
      }
    });

    // Win32 strips trailing dots and spaces per component, so these name the
    // parent directory there even though they are not literally "..".
    test('rejects Win32 aliases of the parent directory', () {
      for (final hostile in [
        '.. ',
        '..  /etc/passwd',
        'lib/.. /.. /evil.dll',
        '...',
        r'lib\.. \evil.dll',
        '. ',
      ]) {
        expect(
          ArchiveEntryPath.sanitize(hostile),
          isNull,
          reason: 'expected "$hostile" to be refused',
        );
      }
    });

    test('rejects an NTFS alternate data stream', () {
      expect(ArchiveEntryPath.sanitize('bin/xcross:evil'), isNull);
      expect(ArchiveEntryPath.sanitize(r'lib/x.dll:$DATA'), isNull);
    });
  });

  group('resolve', () {
    test('lands inside the destination root', () {
      final root = Directory.systemTemp.path;
      expect(
        ArchiveEntryPath.resolve(root, 'bin/xcross'),
        p.join(p.normalize(p.absolute(root)), 'bin', 'xcross'),
      );
    });

    test('refuses an entry that escapes the destination root', () {
      final root = p.join(Directory.systemTemp.path, 'payload');
      for (final hostile in ['../outside', '/absolute', '..']) {
        expect(
          ArchiveEntryPath.resolve(root, hostile),
          isNull,
          reason: 'expected "$hostile" to be refused',
        );
      }
    });

    test('refuses an entry that resolves to the root itself', () {
      expect(ArchiveEntryPath.resolve(Directory.systemTemp.path, '.'), isNull);
    });
  });
}
