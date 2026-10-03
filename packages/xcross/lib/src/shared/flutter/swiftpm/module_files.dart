import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

final class SwiftPmModuleFiles {
SwiftPmModuleFiles({required this.fileSystem});
final SwiftPmArtifactFileSystem fileSystem;
static bool ignoredPackageEvidencePath(String packageDir, String path) {
    final relative = p.relative(path, from: packageDir);
    final parts = p.split(relative);
    return parts.any(
      (part) => part == '.git' || part == '.build' || part == '.xcross',
    );
  }

String resolveModuleReference(
    String packageDir,
    String reference, {
    required bool directory,
  }) {
    final normalized = p.normalize(reference);
    final matches = <String>[];
    for (final entity in fileSystem.directory(
      packageDir,
    ).listSync(recursive: true, followLinks: false)) {
      if (SwiftPmModuleFiles.ignoredPackageEvidencePath(packageDir, entity.path)) {
        continue;
      }
      if (directory ? entity is! Directory : entity is! File) continue;
      final relative = p.normalize(p.relative(entity.path, from: packageDir));
      if (relative == normalized ||
          relative.endsWith('${p.separator}$normalized') ||
          p.basename(relative) == p.basename(normalized)) {
        matches.add(entity.path);
      }
    }
    if (matches.length != 1) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module: ${directory ? 'directory' : 'header'} '
        '"$reference" has ${matches.length} matches in $packageDir.',
      );
    }
    return p.normalize(p.absolute(matches.single));
  }

String absoluteNestedModuleHeaders(String packageDir, String nested) {
    final result = nested.replaceAllMapped(
      RegExp(r'((?:umbrella\s+)?header\s+)"([^"]+)"'),
      (match) {
        final resolved = resolveModuleReference(
          packageDir,
          match[2]!,
          directory: false,
        );
        return '${match[1]}"${SwiftPmFilesystem.swiftPath(resolved)}"';
      },
    );
    return result.replaceAllMapped(RegExp(r'(umbrella\s+)"([^"]+)"'), (match) {
      final resolved = resolveModuleReference(
        packageDir,
        match[2]!,
        directory: true,
      );
      return '${match[1]}"${SwiftPmFilesystem.swiftPath(resolved)}"';
    });
  }
}
