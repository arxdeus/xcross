import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/build/pbxproj.dart';
import 'package:xcross/src/shared/flutter/project/pbx_project_reader.dart';

/// Stages the application target's Xcode resources into an app bundle.
@internal
final class IosBundleResources {
  IosBundleResources(
    this.fileSystem,
    this.paths,
    this.projects, {
    required this.copier,
  });
  final RecursiveDirectoryCopier copier;

  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final PbxProjectReader projects;

  Future<void> stage({
    required String projectRoot,
    required String bundleDir,
  }) async {
    final pbxprojPath = projects.findPbxproj(projectRoot);
    final project = pbxprojPath == null
        ? null
        : projects.parseFile(pbxprojPath);
    final target = project?.applicationTarget;
    if (project == null || target == null) return;

    final infoPlist = _resolveBuildSettingPath(
      project,
      project.buildSetting(target, 'INFOPLIST_FILE'),
    );
    final resources = <String>{
      ...project.buildPhaseFiles(target, 'PBXResourcesBuildPhase'),
      ...project
          .synchronizedFiles(target, fileSystem: fileSystem)
          .where(PbxProject.isTargetResource),
    };
    for (var source in resources) {
      if (paths.extension(source) == '.xcassets') continue;
      if (paths.basename(source) == 'AppFrameworkInfo.plist') continue;
      if (infoPlist != null && paths.equals(source, infoPlist)) continue;

      if (paths.extension(source) == '.storyboard') {
        source = paths.setExtension(source, '.storyboardc');
      }

      var sourceType = _sourceType(source);
      if (sourceType == FileSystemEntityType.notFound) {
        final relocated = _findRelocatedResource(projectRoot, source);
        if (relocated == null) continue;
        source = relocated;
        sourceType = _sourceType(source);
      }

      final localization = _nearestLocalization(source);
      final isBaseStoryboard =
          paths.extension(source) == '.storyboardc' &&
          localization != null &&
          paths.basename(localization) == 'Base.lproj';
      final destinationDirectory = localization == null || isBaseStoryboard
          ? bundleDir
          : paths.join(bundleDir, paths.basename(localization));
      final destination = paths.join(
        destinationDirectory,
        paths.basename(source),
      );
      await fileSystem.directory(destinationDirectory).create(recursive: true);

      if (sourceType == FileSystemEntityType.directory) {
        final existing = fileSystem.directory(destination);
        if (existing.existsSync()) await existing.delete(recursive: true);
        await copier.copy(source, destination);
      } else if (sourceType == FileSystemEntityType.file) {
        await fileSystem.file(source).copy(fileSystem.file(destination).path);
      }
    }
  }

  FileSystemEntityType _sourceType(String source) {
    if (fileSystem.link(source).existsSync()) return FileSystemEntityType.link;
    if (fileSystem.directory(source).existsSync()) {
      return FileSystemEntityType.directory;
    }
    if (fileSystem.file(source).existsSync()) return FileSystemEntityType.file;
    return FileSystemEntityType.notFound;
  }

  String? _findRelocatedResource(String projectRoot, String unresolved) {
    final ios = fileSystem.directory(paths.join(projectRoot, 'ios'));
    if (!ios.existsSync()) return null;
    final name = paths.basename(unresolved);
    final matches = ios
        .listSync(recursive: true, followLinks: false)
        .where((entity) => paths.basename(entity.path) == name)
        .map((entity) => entity.path)
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  String? _resolveBuildSettingPath(PbxProject project, String? value) {
    if (value == null || value.isEmpty || value.contains(r'$')) return null;
    return paths.normalize(
      paths.isAbsolute(value)
          ? value
          : paths.join(project.projectDirectory, value),
    );
  }

  String? _nearestLocalization(String path) {
    var directory = paths.dirname(path);
    while (directory != paths.dirname(directory)) {
      if (paths.extension(directory) == '.lproj') return directory;
      directory = paths.dirname(directory);
    }
    return null;
  }
}
