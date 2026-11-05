import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

@internal
final class LaunchStoryboardLocator {
  const LaunchStoryboardLocator(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  /// Finds `<name>.storyboard` under `<projectRoot>/ios`, preferring
  /// `Base.lproj`. Returns null when absent.
  String? locate(String projectRoot, String name) {
    final root = fileSystem.directory(paths.join(projectRoot, 'ios'));
    if (!root.existsSync()) return null;
    final found = <String>[];
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (paths.basename(e.path) == '$name.storyboard' &&
          fileSystem.file(e.path).existsSync()) {
        found.add(e.path);
      }
    }
    if (found.isEmpty) return null;
    found.sort((a, b) {
      int rank(String s) => s.contains('Base.lproj') ? 0 : 1;
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.compareTo(b);
    });
    return found.first;
  }
}
