import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/flutter/build/pbxproj.dart';

/// Stages the application target's Xcode resources into an app bundle.
@internal
Future<void> stageIosBundleResources({
  required String projectRoot,
  required String bundleDir,
}) async {
  final pbxprojPath = PbxProject.findPbxproj(projectRoot);
  final project = pbxprojPath == null
      ? null
      : PbxProject.parseFile(pbxprojPath);
  final target = project?.applicationTarget;
  if (project == null || target == null) return;

  final infoPlist = _resolveBuildSettingPath(
    project,
    project.buildSetting(target, 'INFOPLIST_FILE'),
  );
  final resources = <String>{
    ...project.buildPhaseFiles(target, 'PBXResourcesBuildPhase'),
    ...project.synchronizedFiles(target).where(PbxProject.isTargetResource),
  };
  for (var source in resources) {
    if (p.extension(source) == '.xcassets') continue;
    if (p.basename(source) == 'AppFrameworkInfo.plist') continue;
    if (infoPlist != null && p.equals(source, infoPlist)) continue;

    if (p.extension(source) == '.storyboard') {
      source = p.setExtension(source, '.storyboardc');
    }

    final sourceType = FileSystemEntity.typeSync(source, followLinks: false);
    if (sourceType == FileSystemEntityType.notFound) continue;

    final localization = _nearestLocalization(source);
    final isBaseStoryboard =
        p.extension(source) == '.storyboardc' &&
        localization != null &&
        p.basename(localization) == 'Base.lproj';
    final destinationDirectory = localization == null || isBaseStoryboard
        ? bundleDir
        : p.join(bundleDir, p.basename(localization));
    final destination = p.join(destinationDirectory, p.basename(source));
    await Directory(destinationDirectory).create(recursive: true);

    if (sourceType == FileSystemEntityType.directory) {
      final existing = Directory(destination);
      if (existing.existsSync()) await existing.delete(recursive: true);
      await copyDirectoryPreservingSymlinks(source, destination);
    } else if (sourceType == FileSystemEntityType.file) {
      await File(source).copy(destination);
    }
  }
}

String? _resolveBuildSettingPath(PbxProject project, String? value) {
  if (value == null || value.isEmpty || value.contains(r'$')) return null;
  return p.normalize(
    p.isAbsolute(value) ? value : p.join(project.projectDirectory, value),
  );
}

String? _nearestLocalization(String path) {
  var directory = p.dirname(path);
  while (directory != p.dirname(directory)) {
    if (p.extension(directory) == '.lproj') return directory;
    directory = p.dirname(directory);
  }
  return null;
}
