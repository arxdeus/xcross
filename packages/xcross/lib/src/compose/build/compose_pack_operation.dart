import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/compose_packer.dart';
import 'package:xcross/src/compose/models/compose_build_options.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/models/pack_result.dart';

typedef ComposeCurrentDirectory = String Function();
typedef ComposeDetectProject =
    KmpProject Function(String root, {String? bundleId, String? appName});
typedef ComposePackProject =
    Future<PackResult> Function({
      required KmpProject project,
      required ComposeBuildOptions options,
    });

abstract final class ComposePackOperation {
  static final ComposePackOperationWithSeams _default = withSeams();

  static Future<PackResult> pack({
    required ComposeBuildOptions options,
    bool requireRunnableApp = false,
  }) => _default.pack(options: options, requireRunnableApp: requireRunnableApp);

  static ComposePackOperationWithSeams withSeams({
    ComposeCurrentDirectory? currentDirectory,
    ComposeDetectProject? detectProject,
    ComposePackProject? packProject,
  }) => ComposePackOperationWithSeams(
    currentDirectory: currentDirectory ?? (() => Directory.current.path),
    detectProject: detectProject ?? KmpProject.detect,
    packProject: packProject ?? _defaultPackProject,
  );

  static Future<PackResult> _defaultPackProject({
    required KmpProject project,
    required ComposeBuildOptions options,
  }) => ComposePacker(project: project, options: options).pack();
}

final class ComposePackOperationWithSeams {
  const ComposePackOperationWithSeams({
    required ComposeCurrentDirectory currentDirectory,
    required ComposeDetectProject detectProject,
    required ComposePackProject packProject,
  }) : _currentDirectory = currentDirectory,
       _detectProject = detectProject,
       _packProject = packProject;

  final ComposeCurrentDirectory _currentDirectory;
  final ComposeDetectProject _detectProject;
  final ComposePackProject _packProject;

  Future<PackResult> pack({
    required ComposeBuildOptions options,
    bool requireRunnableApp = false,
  }) async {
    final project = _detectProject(
      _currentDirectory(),
      bundleId: options.bundleId,
      appName: options.appName,
    );
    if (project.entryKind == KmpEntryKind.frameworkOnly &&
        (requireRunnableApp || options.ipa)) {
      throw XcrossError('This KMP project produces a framework only.');
    }
    await _deleteStaleOutputs(project);
    return _packProject(project: project, options: options);
  }

  Future<void> _deleteStaleOutputs(KmpProject project) async {
    for (final path in [
      p.join(project.root, 'build', 'xcross-ios', '${project.appName}.app'),
      p.join(
        project.root,
        'build',
        'xcross-ios',
        '${project.baseName}.framework',
      ),
    ]) {
      final entityType = FileSystemEntity.typeSync(path);
      if (entityType == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (entityType == FileSystemEntityType.file ||
          entityType == FileSystemEntityType.link) {
        await File(path).delete();
      }
    }
  }
}
