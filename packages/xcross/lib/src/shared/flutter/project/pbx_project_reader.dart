import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/pbxproj.dart';

@internal
final class PbxProjectReader {
  PbxProjectReader(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  /// Path to the iOS project's pbxproj, preferring an application project.
  ///
  /// `Runner.xcodeproj` wins only when it is parseable and contains an
  /// application target. Otherwise another valid application project is used.
  /// Non-application consumers receive the first parseable project in stable
  /// path order (or the first candidate if every project is malformed).
  String? findPbxproj(String projectRoot) {
    final iosDir = fileSystem.directory(paths.join(projectRoot, 'ios'));
    if (!iosDir.existsSync()) return null;

    final candidates =
        iosDir
            .listSync()
            .whereType<Directory>()
            .where((directory) => directory.path.endsWith('.xcodeproj'))
            .map(
              (directory) => fileSystem.file(
                paths.join(directory.path, 'project.pbxproj'),
              ),
            )
            .where((file) => file.existsSync())
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (candidates.isEmpty) return null;

    final parsed = <File, PbxProject?>{
      for (final candidate in candidates) candidate: parseFile(candidate.path),
    };
    final applicationProjects = candidates
        .where((candidate) => parsed[candidate]?.applicationTarget != null)
        .toList();
    if (applicationProjects.isNotEmpty) {
      return applicationProjects
          .firstWhere(
            (candidate) =>
                paths.basename(candidate.parent.path) == 'Runner.xcodeproj',
            orElse: () => applicationProjects.first,
          )
          .path;
    }

    return candidates
        .firstWhere(
          (candidate) => parsed[candidate] != null,
          orElse: () => candidates.first,
        )
        .path;
  }

  /// Parse the pbxproj at [path]. Returns null when it cannot be read.
  PbxProject? parseFile(String path) {
    final file = fileSystem.file(path);
    if (!file.existsSync()) return null;
    try {
      return PbxProject.parse(
        file.readAsStringSync(),
        // <root>/ios/Runner.xcodeproj/project.pbxproj → <root>/ios
        projectDirectory: paths.dirname(paths.dirname(path)),
      );
    } on FormatException {
      return null;
    }
  }
}
