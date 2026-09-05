import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Whether this process can create real symbolic links.
///
/// Always true off Windows. On Windows it needs Developer Mode or the
/// `SeCreateSymbolicLinkPrivilege` (administrators, including GitHub-hosted
/// runners); both Dart's `Link.create` and Git for Windows ask for
/// `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`, so one probe answers for
/// both. The verdict is cached for the process.
abstract final class HostSymlinkCapability {
  static bool? _cached;

  static Future<bool> probe({String? directory}) async {
    final cached = _cached;
    if (cached != null) return cached;
    if (!Platform.isWindows) return _cached = true;

    final root = await Directory(
      directory ?? Directory.systemTemp.path,
    ).createTemp('xcross-symlink-probe-');
    try {
      final target = File(p.join(root.path, 'target'))..writeAsStringSync('');
      final link = Link(p.join(root.path, 'link'));
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

  @visibleForTesting
  static bool? get override => _cached;

  @visibleForTesting
  static set override(bool? value) => _cached = value;
}
