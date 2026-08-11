import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/compose_info_plist.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/errors.dart';

abstract final class ComposeAppAssembler {
  static Future<String> assemble({
    required KmpProject project,
    required String runnerPath,
    required String frameworkPath,
  }) async {
    final runner = File(runnerPath);
    if (!runner.existsSync()) {
      throw XcrossError('Runner binary not found: $runnerPath');
    }
    final framework = Directory(frameworkPath);
    if (!framework.existsSync()) {
      throw XcrossError('Compose framework not found: $frameworkPath');
    }
    final frameworkBinary = File(p.join(frameworkPath, project.baseName));
    if (!frameworkBinary.existsSync()) {
      throw XcrossError(
        'Compose framework binary not found: ${frameworkBinary.path}',
      );
    }

    final appPath = p.join(
      project.root,
      'build',
      'xcross-ios',
      '${project.appName}.app',
    );
    final appDir = Directory(appPath);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
    await Directory(p.join(appPath, 'Frameworks')).create(recursive: true);

    final runnerDest = p.join(appPath, 'Runner');
    await runner.copy(runnerDest);
    await File(
      p.join(appPath, 'Info.plist'),
    ).writeAsString(ComposeInfoPlist.build(project: project));
    final frameworkDest = p.join(
      appPath,
      'Frameworks',
      '${project.baseName}.framework',
    );
    await _copyDirectoryNoSymlinks(framework, Directory(frameworkDest));

    if (!Platform.isWindows) {
      ProcessRunner.makeExecutable(runnerDest);
      ProcessRunner.makeExecutable(p.join(frameworkDest, project.baseName));
    }
    return appPath;
  }

  static Future<void> _copyDirectoryNoSymlinks(
    Directory source,
    Directory destination,
  ) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final target = p.join(destination.path, p.basename(entity.path));
      if (entity is Link) continue;
      if (entity is Directory) {
        await _copyDirectoryNoSymlinks(entity, Directory(target));
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        await entity.copy(target);
      }
    }
  }
}
