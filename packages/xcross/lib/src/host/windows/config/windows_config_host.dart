import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/config/config_host.dart';

final class WindowsConfigHost implements ConfigHostInterface {
  const WindowsConfigHost();

  @override
  RegExp get variables => RegExp('%([A-Za-z_][A-Za-z0-9_]*)%');

  @override
  String expandHome(String value, String Function(String name) variable) =>
      value;

  @override
  bool isExecutable(String path, FileStat stat) => const {
    '.exe',
    '.com',
    '.bat',
    '.cmd',
  }.contains(p.windows.extension(path).toLowerCase());

  @override
  Future<void> replace(File temporary, File destination) async {
    if (!destination.existsSync()) {
      await temporary.rename(destination.path);
      return;
    }
    final backup = File(
      '${destination.path}.bak-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    await destination.rename(backup.path);
    try {
      await temporary.rename(destination.path);
    } on FileSystemException {
      if (destination.existsSync()) await destination.delete();
      await backup.rename(destination.path);
      rethrow;
    }
    await backup.delete();
  }
}
