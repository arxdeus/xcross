import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Package an `.app` into an `.ipa` (`Payload/<app>` zipped), pure Dart.
///
/// Symlinks are dereferenced (iOS `.app` bundles are flat and codesign rejects
/// interior symlinks, so this matches `zip` without `-y`). Unix file modes are
/// recorded on each entry. Returns the `.ipa` path.
Future<String> packageIpa(String appPath) async {
  final appDir = Directory(appPath);
  final appName = p.basename(appPath);
  final ipaPath = p.join(
    p.dirname(appPath),
    '${p.basenameWithoutExtension(appPath)}.ipa',
  );
  final ipaFile = File(ipaPath);
  if (ipaFile.existsSync()) ipaFile.deleteSync();

  final archive = Archive();
  // list() follows symlinks by default → they resolve to real files/dirs.
  await for (final entity in appDir.list(recursive: true)) {
    if (entity is! File) continue; // dirs are implicit from entry paths
    final rel = p.relative(entity.path, from: appPath);
    final entryName = p.posix.joinAll(['Payload', appName, ...p.split(rel)]);
    final bytes = await entity.readAsBytes();
    final file = ArchiveFile.bytes(entryName, bytes);
    file.mode = entity.statSync().mode & 0xFFF;
    archive.addFile(file);
  }

  final zipBytes = ZipEncoder().encode(archive);
  await ipaFile.writeAsBytes(zipBytes);
  return ipaPath;
}
