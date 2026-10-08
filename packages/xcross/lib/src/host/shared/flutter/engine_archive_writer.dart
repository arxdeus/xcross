import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

@internal
final class FlutterEngineArchiveWriter<T extends PlatformHostInterface> {
  const FlutterEngineArchiveWriter(this.host);

  final T host;

  Future<void> extractZip(String source, String destination) async {
    final input = InputFileStream(host.fileSystem.file(source).path);
    Archive? archive;
    try {
      archive = ZipDecoder().decodeStream(input);
      await extract(archive, destination);
    } finally {
      try {
        await archive?.clear();
      } finally {
        await input.close();
      }
    }
  }

  Future<void> extract(Archive archive, String destination) async {
    final paths = host.paths.context;
    final root = paths.normalize(paths.absolute(destination));
    await host.fileSystem.directory(root).create(recursive: true);
    final links = <(String, String)>[];
    for (final entry in archive) {
      final components = p.posix.split(p.posix.normalize(entry.name));
      if (p.posix.isAbsolute(entry.name) || p.windows.isAbsolute(entry.name)) {
        continue;
      }
      final outputPath = paths.normalize(paths.joinAll([root, ...components]));
      if (!paths.isWithin(root, outputPath)) continue;
      await host.fileSystem
          .directory(paths.dirname(outputPath))
          .create(recursive: true);
      if (entry.isSymbolicLink) {
        final target = entry.symbolicLink!;
        if (p.posix.isAbsolute(target) || p.windows.isAbsolute(target)) {
          continue;
        }
        final resolved = paths.normalize(
          paths.joinAll([paths.dirname(outputPath), ...p.posix.split(target)]),
        );
        if (!paths.isWithin(root, resolved)) continue;
        links.add((outputPath, paths.joinAll(p.posix.split(target))));
      } else if (entry.isDirectory) {
        await host.fileSystem.directory(outputPath).create(recursive: true);
      } else if (entry.isFile) {
        final output = OutputFileStream(host.fileSystem.file(outputPath).path);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        host.fileSystem.setPermissions(outputPath, entry.unixPermissions);
      }
    }
    final pending = Map<String, String>.fromEntries(
      links.map((entry) => MapEntry(entry.$1, entry.$2)),
    );
    final active = <String>{};
    Future<void> materialize(String path) async {
      final target = pending[path];
      if (target == null) return;
      if (!active.add(path)) {
        throw FileSystemException('Archive link cycle', path);
      }
      final resolved = paths.normalize(paths.join(paths.dirname(path), target));
      for (final candidate in pending.keys.toList()) {
        if (candidate == resolved ||
            paths.isWithin(resolved, candidate) ||
            paths.isWithin(candidate, resolved)) {
          await materialize(candidate);
        }
      }
      await host.fileSystem.createArchiveLink(path, target);
      pending.remove(path);
      active.remove(path);
    }

    for (final (path, _) in links) {
      await materialize(path);
    }
  }
}
