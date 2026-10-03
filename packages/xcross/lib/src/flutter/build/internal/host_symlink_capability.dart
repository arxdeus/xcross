import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;

final class HostSymlinkCapability {
  HostSymlinkCapability(this.host);
  final PlatformHostInterface host;
  bool? _cached;
  Future<bool> probe({String? directory}) async {
    final cached = _cached;
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
        return _cached = false;
      }
      return _cached = FileSystemEntity.isLinkSync(link.path);
    } finally {
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  }

  bool? get override => _cached;
  set override(bool? value) => _cached = value;
}
