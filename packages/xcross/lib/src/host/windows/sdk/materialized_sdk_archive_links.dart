import 'dart:io';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_archive_links.dart';
import 'package:xcross/src/shared/sdk/sdk_directory_copy.dart';

final class MaterializedSdkArchiveLinks<T extends PlatformHostInterface>
    implements SdkArchiveLinksInterface {
  const MaterializedSdkArchiveLinks(this.host);
  final T host;
  @override
  Future<void> createLinks(
    Map<String, String> links, {
    void Function(int done, int total)? onProgress,
  }) async {
    for (final link in links.entries) {
      final target = link.value.toLowerCase();
      final destination = link.key.toLowerCase();
      if (FileSystemEntity.typeSync(host.paths.ioPath(link.value)) ==
              FileSystemEntityType.directory &&
          (target == destination ||
              host.paths.context.isWithin(target, destination))) {
        throw XcrossError(
          'Cannot materialize an SDK directory symlink inside its target: '
          '${link.key}',
        );
      }
    }
    final pending = Map<String, String>.from(links);
    while (pending.isNotEmpty) {
      var progressed = false;
      for (final link in pending.entries.toList()) {
        final target = link.value;
        final type = FileSystemEntity.typeSync(host.paths.ioPath(target));
        if (type == FileSystemEntityType.notFound) continue;
        if (type == FileSystemEntityType.directory &&
            pending.keys.any(
              (other) =>
                  other != link.key &&
                  host.paths.context.isWithin(
                    target.toLowerCase(),
                    other.toLowerCase(),
                  ),
            )) {
          continue;
        }

        switch (type) {
          case FileSystemEntityType.directory:
            await SdkDirectoryCopy(host).copy(target, link.key);
          case FileSystemEntityType.file:
            await File(
              host.paths.ioPath(target),
            ).copy(host.paths.ioPath(link.key));
          default:
            throw XcrossError('Unsupported SDK symlink target: ${link.value}');
        }
        pending.remove(link.key);
        progressed = true;
        onProgress?.call(links.length - pending.length, links.length);
      }
      if (!progressed) {
        throw XcrossError(
          'Could not resolve SDK symlinks: ${pending.values.join(', ')}',
        );
      }
    }
  }
}
