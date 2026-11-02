import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Groups `.ipa` packaging.
@internal
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
      file.mode = entryMode(entity.statSync().mode, bytes);
      archive.addFile(file);
    }

    final zipBytes = ZipEncoder().encode(archive);
    await ipaFile.writeAsBytes(zipBytes);
    return ipaPath;
  }

  /// Unix mode recorded for an IPA entry.
  ///
  /// Windows `stat` has no exec bit (and reports `0666`-style modes), so a
  /// Mach-O main executable or framework binary would land in the IPA
  /// non-executable and installd would refuse to launch it. Mach-O files are
  /// therefore always `0755`; other files keep their host mode, falling back
  /// to `0644` when the host reports none.
  @visibleForTesting
  static int entryMode(int statMode, List<int> bytes) {
    if (_isMachO(bytes)) return 0x1ED; // 0755
    final mode = statMode & 0x1FF;
    return mode == 0 ? 0x1A4 : mode;
  }

  static bool _isMachO(List<int> b) {
    if (b.length < 4) return false;
    final be = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    return be == 0xFEEDFACE ||
        be == 0xFEEDFACF ||
        be == 0xCEFAEDFE ||
        be == 0xCFFAEDFE ||
        be == 0xCAFEBABE ||
        be == 0xCAFEBABF;
  }
}
