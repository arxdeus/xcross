import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';

/// Stages optional resources from the iOS Runner into an app bundle.
@internal
Future<void> stageIosBundleResources({
  required String projectRoot,
  required String bundleDir,
}) async {
  final runnerDir = p.join(projectRoot, 'ios', 'Runner');
  const storyboards = [
    'Base.lproj/LaunchScreen.storyboardc',
    'Base.lproj/Main.storyboardc',
  ];
  for (final rel in storyboards) {
    final src = p.join(runnerDir, rel);
    if (!Directory(src).existsSync()) continue;
    final dst = p.join(bundleDir, p.basename(src));
    final dstDir = Directory(dst);
    if (dstDir.existsSync()) {
      await dstDir.delete(recursive: true);
    }
    await copyDirectoryPreservingSymlinks(src, dst);
  }

  final firebasePlistCandidates = [
    p.join(runnerDir, 'GoogleService-Info.plist'),
    p.join(projectRoot, 'ios', 'GoogleService-Info.plist'),
  ];
  for (final source in firebasePlistCandidates) {
    final file = File(source);
    if (!file.existsSync()) continue;
    await file.copy(p.join(bundleDir, 'GoogleService-Info.plist'));
    break;
  }
}
