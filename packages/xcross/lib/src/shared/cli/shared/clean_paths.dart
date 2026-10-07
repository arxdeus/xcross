import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

/// Shared deletion and reporting for the `clean` subcommands of
/// `xcross flutter`, `xcross compose`, and `xcross sdk`.
@internal
final class CleanPaths {
  const CleanPaths(this.host, this.log);

  final PlatformHostInterface host;
  final Log log;

  /// Recursively deletes every existing entry in [paths], returning the paths
  /// actually removed in the order given. Missing paths are skipped, so a
  /// second clean is a no-op rather than an error.
  Future<List<String>> delete(Iterable<String> paths) async {
    final files = host.fileSystem;
    final removed = <String>[];
    for (final path in paths) {
      final target = host.paths.ioPath(path);
      // A link is removed itself, never followed into its target.
      final link = files.link(target);
      final directory = files.directory(target);
      final file = files.file(target);
      if (link.existsSync()) {
        await link.delete();
      } else if (directory.existsSync()) {
        await directory.delete(recursive: true);
      } else if (file.existsSync()) {
        await file.delete();
      } else {
        continue;
      }
      removed.add(path);
    }
    return removed;
  }

  /// Logs each removed path, then a summary line.
  void report(List<String> removed, {required String nothingFound}) {
    for (final path in removed) {
      log.logStatus('Removed $path');
    }
    if (removed.isEmpty) {
      log.logStatus(nothingFound);
    } else {
      log.logDone('Clean complete');
    }
  }
}
