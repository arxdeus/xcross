import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/internal/archive_entry_path.dart';

@internal
final class ArchiveExtractor<T extends PlatformHostInterface> {
  const ArchiveExtractor(this.host);
  final T host;
  Future<void> extractArchive(File archiveFile, Directory destination) async {
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
        await host.fileSystem.directory(target).create(recursive: true);
        continue;
      }
      await host.fileSystem
          .directory(p.dirname(target))
          .create(recursive: true);
      await host.fileSystem
          .file(target)
          .writeAsBytes(entry.content as List<int>);
      if (_looksExecutable(entry)) {
        host.fileSystem.makeExecutable(target);
      }
    }
  }

  static bool _looksExecutable(ArchiveFile entry) => (entry.mode & 0x49) != 0;
}
