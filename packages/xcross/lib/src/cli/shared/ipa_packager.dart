import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;

/// Groups `.ipa` packaging.
final class IpaPackager {
  const IpaPackager({required this.host});

  final PlatformHostInterface host;

  /// Package an `.app` into an `.ipa` (`Payload/<app>` zipped), pure Dart.
  ///
  /// Symlinks are dereferenced (iOS `.app` bundles are flat and codesign
  /// rejects interior symlinks, so this matches `zip` without `-y`). Unix
  /// file modes are recorded on each entry. Returns the `.ipa` path.
  Future<String> package(String appPath) async {
    final paths = host.paths.context;
    final appDir = host.fileSystem.directory(appPath);
    final appName = paths.basename(appPath);
    final ipaPath = paths.join(
      paths.dirname(appPath),
      '${paths.basenameWithoutExtension(appPath)}.ipa',
    );
    final ipaFile = host.fileSystem.file(ipaPath);
    if (ipaFile.existsSync()) ipaFile.deleteSync();

    final archive = Archive();
    // list() follows symlinks by default → they resolve to real files/dirs.
    await for (final entity in appDir.list(recursive: true)) {
      if (entity is! File) continue; // dirs are implicit from entry paths
      final rel = paths.relative(entity.path, from: appDir.path);
      final entryName = p.posix.joinAll([
        'Payload',
        appName,
        ...paths.split(rel),
      ]);
      final bytes = await entity.readAsBytes();
      final file = ArchiveFile.bytes(entryName, bytes);
      file.mode = entity.statSync().mode & 0xFFF;
      archive.addFile(file);
    }

    final zipBytes = ZipEncoder().encode(archive);
    await ipaFile.writeAsBytes(zipBytes);
    return ipaPath;
  }
}
