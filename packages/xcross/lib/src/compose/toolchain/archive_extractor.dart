import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/internal/archive_entry_path.dart';

abstract final class ArchiveExtractor {
  static Future<void> extractArchive(
    File archiveFile,
    Directory destination,
  ) async {
    final bytes = await archiveFile.readAsBytes();
    final name = p.basename(archiveFile.path);
    final archive = name.endsWith('.zip')
        ? ZipDecoder().decodeBytes(bytes)
        : TarDecoder().decodeBytes(const GZipDecoder().decodeBytes(bytes));

    await destination.create(recursive: true);
    for (final entry in archive.files) {
      if (entry.isSymbolicLink) {
        throw XcrossError(
          'refusing to extract $name: link entry "${entry.name}"',
        );
      }
      final target = ArchiveEntryPath.resolve(destination.path, entry.name);
      if (target == null) {
        throw XcrossError(
          'refusing to extract $name: entry "${entry.name}" escapes destination',
        );
      }
      if (!entry.isFile) {
        await Directory(target).create(recursive: true);
        continue;
      }
      await Directory(p.dirname(target)).create(recursive: true);
      await File(target).writeAsBytes(entry.content as List<int>);
      if (!Platform.isWindows && _looksExecutable(entry)) {
        ProcessRunner.makeExecutable(target);
      }
    }
  }

  static bool _looksExecutable(ArchiveFile entry) => (entry.mode & 0x49) != 0;
}
