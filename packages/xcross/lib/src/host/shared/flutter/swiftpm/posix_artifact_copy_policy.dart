import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';

final class PosixSwiftPmArtifactCopyPolicy
    implements SwiftPmArtifactCopyPolicy {
  const PosixSwiftPmArtifactCopyPolicy(this.fileSystem);
  final SwiftPmArtifactFileSystem fileSystem;
  @override
  Future<void> copy({
    required String source,
    required Directory destination,
    required Duration timeout,
  }) async {
    final elapsed = Stopwatch()..start();
    Future<void> copyTree(String root, String output) async {
      await for (final entity
          in fileSystem.directory(root).list(followLinks: false)) {
        if (elapsed.elapsed > timeout) {
          throw FileSystemException(
            'SwiftPM binary artifact copy timed out after $timeout',
            source,
          );
        }
        if (await fileSystem.isLinkOrReparsePoint(entity.path)) {
          throw FileSystemException(
            'SwiftPM binary artifact copy refuses links or reparse points',
            entity.path,
          );
        }
        final target = p.join(output, p.basename(entity.path));
        final type = fileSystem.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await fileSystem.directory(target).create();
          await copyTree(entity.path, target);
        } else if (type == FileSystemEntityType.file) {
          await fileSystem.file(entity.path).copy(target);
        } else {
          throw FileSystemException(
            'SwiftPM binary artifact copy refuses unsupported entries',
            entity.path,
          );
        }
      }
    }

    await copyTree(source, destination.path);
  }
}
