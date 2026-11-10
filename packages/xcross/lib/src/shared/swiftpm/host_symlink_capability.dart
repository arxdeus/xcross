import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

@internal
final class HostSymlinkCapability {
  HostSymlinkCapability(this.host);
  final PlatformHostInterface host;
  bool? override;
  Future<bool> probe({String? directory}) async {
    final cached = override;
    if (cached != null) return cached;
    final root = await host.fileSystem
        .directory(directory ?? host.paths.temporaryRoot)
        .createTemp('xcross-symlink-probe-');
    try {
      final target = host.fileSystem.file(p.join(root.path, 'target'))
        ..writeAsStringSync('');
      final link = host.fileSystem.link(p.join(root.path, 'link'));
      try {
        link.createSync(target.path);
      } on FileSystemException {
        return override = false;
      }
      return override = link.existsSync();
    } finally {
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  }
}
