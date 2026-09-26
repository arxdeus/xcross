import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/clean_command.dart';
import 'package:xcross/src/cli/runner.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';

void main() {
  test('clean is registered by the top-level runner', () {
    expect(XcrossCli.buildRunner().commands.keys, contains('clean'));
  });

  test('removes project native assets and SwiftPM workspace', () async {
    final project = Directory.systemTemp.createTempSync('xcross_clean_project');
    final cache = Directory.systemTemp.createTempSync('xcross_clean_cache');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });
    final nativeAssets = Directory(
      p.join(project.path, 'build', 'xcross-native-assets'),
    )..createSync(recursive: true);
    final appleTools = Directory(
      p.join(project.path, 'build', 'xcross-apple-tools'),
    )..createSync(recursive: true);
    final workspace = SwiftPmWorkspace.forProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );
    final swiftPm = Directory(workspace.root)..createSync(recursive: true);

    await CleanCommand.cleanProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );

    expect(nativeAssets.existsSync(), isFalse);
    expect(appleTools.existsSync(), isFalse);
    expect(swiftPm.existsSync(), isFalse);
  });

  test('preserves unrelated build output and shared SwiftPM caches', () async {
    final project = Directory.systemTemp.createTempSync('xcross_clean_project');
    final cache = Directory.systemTemp.createTempSync('xcross_clean_cache');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });
    final unrelated = File(p.join(project.path, 'build', 'keep.txt'))
      ..createSync(recursive: true);
    final shared = File(
      p.join(cache.path, 'swiftpm', 'binary-artifacts-v1', 'keep.txt'),
    )..createSync(recursive: true);

    await CleanCommand.cleanProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );

    expect(unrelated.existsSync(), isTrue);
    expect(shared.existsSync(), isTrue);
  });

  test('succeeds when project caches do not exist', () async {
    final project = Directory.systemTemp.createTempSync('xcross_clean_project');
    final cache = Directory.systemTemp.createTempSync('xcross_clean_cache');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });

    await CleanCommand.cleanProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );
    await CleanCommand.cleanProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );
  });
}
